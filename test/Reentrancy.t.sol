// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {TickTockHook} from "../src/TickTockHook.sol";
import {TickTockTestBase} from "./utils/TickTockTestBase.sol";

/// @notice Makes one call of its choice the first time it's used, then behaves normally. It records the outcome and
/// swallows any revert, so the outer action carries on.
abstract contract Reenterer {
    address public target;
    bytes public payload;
    bool public armed;
    bool public reentered;
    bool public reentrySucceeded;
    bytes public reentryResult;

    function arm(address target_, bytes calldata payload_) external {
        (target, payload, armed) = (target_, payload_, true);
    }

    function _reenter() internal {
        if (!armed) return;
        armed = false;
        reentered = true;
        (reentrySucceeded, reentryResult) = target.call(payload);
    }
}

/// @notice A token whose `transferFrom` calls back, like an ERC-777 hook or a malicious token.
contract ReentrantToken is MockERC20, Reenterer {
    constructor() MockERC20("Reentrant", "RE", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _reenter();
        return super.transferFrom(from, to, amount);
    }
}

/// @notice An ETH recipient that calls back when paid.
contract ReentrantRecipient is Reenterer {
    receive() external payable {
        _reenter();
    }
}

contract ReentrancyTest is TickTockTestBase {
    TickTockHook internal hook;
    ReentrantToken internal token;
    PoolKey internal evilKey; // the reentrant token against currency1
    PoolKey internal plainKey; // two plain tokens
    bool internal tokenIs0;

    function setUp() public override {
        super.setUp();
        hook = _createHook(10, _spreads(10, 50, 100));
        token = new ReentrantToken();
        Currency evil = Currency.wrap(address(token));
        tokenIs0 = address(token) < Currency.unwrap(currency1);
        evilKey = tokenIs0
            ? PoolKey(evil, currency1, 3000, 1, IHooks(address(hook)))
            : PoolKey(currency1, evil, 3000, 1, IHooks(address(hook)));
        plainKey = _key(hook, 3000);

        _fund(alice, hook);
        token.mint(alice, USER_FUNDS);
        vm.prank(alice);
        token.approve(address(hook), type(uint256).max);

        // A plain pool with an order, so reentrant calls have something real to act on.
        _deposit(hook, plainKey, alice, 100, 1, true, 1e18);
    }

    /// Alice deposits into the reentrant token's pool, paying with it; the token makes its call mid-deposit.
    function _depositPayingWithToken() internal {
        _deposit(hook, evilKey, alice, 100, 1, tokenIs0, 1e18);
    }

    function _assertBlocked(bytes memory expected) internal view {
        assertTrue(token.reentered(), "the token called back");
        assertFalse(token.reentrySucceeded(), "the reentrant call was refused");
        assertEq(token.reentryResult(), expected);
    }

    function _reentrancyError() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ReentrancyGuardTransient.Reentrancy.selector);
    }

    function test_reenterDeposit() public {
        token.arm(
            address(hook),
            abi.encodeCall(TickTockHook.deposit, (plainKey, 200, 1, true, 1e18, 0, address(token), block.timestamp))
        );
        _depositPayingWithToken();
        _assertBlocked(_reentrancyError());
    }

    function test_reenterWithdraw() public {
        token.arm(address(hook), abi.encodeCall(TickTockHook.withdraw, (uint64(1), 1, address(token), block.timestamp)));
        _depositPayingWithToken();
        _assertBlocked(_reentrancyError());
    }

    function test_reenterFlips() public {
        token.arm(address(hook), abi.encodeCall(TickTockHook.flipLevel, (plainKey, 100)));
        _depositPayingWithToken();
        _assertBlocked(_reentrancyError());
    }

    function test_reenterFlipCrossedAndMovePrice() public {
        _depositPayingWithToken(); // creates the reentrant pool, unarmed

        token.arm(address(hook), abi.encodeCall(TickTockHook.flipCrossed, (plainKey, 10)));
        _deposit(hook, evilKey, alice, 100, 1, tokenIs0, 1e18);
        _assertBlocked(_reentrancyError());

        token.arm(address(hook), abi.encodeCall(TickTockHook.movePrice, (plainKey, TickMath.getSqrtPriceAtTick(-50))));
        _deposit(hook, evilKey, alice, 100, 1, tokenIs0, 1e18);
        _assertBlocked(_reentrancyError());
    }

    /// The pool manager is unlocked during the hook's callback, so anyone can call `swap` then. A swap on a TickTock
    /// pool runs `afterSwap`, which the lock refuses; v4 reports it wrapped.
    function test_reenterThroughAPoolManagerSwap() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(90);
        token.arm(
            address(manager),
            abi.encodeCall(IPoolManager.swap, (plainKey, IPoolManager.SwapParams(true, -1, limit), ""))
        );
        _depositPayingWithToken();
        _assertBlocked(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                _reentrancyError(),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// An ETH recipient that calls back while a withdrawal pays it is refused too.
    function test_reenterFromAnEthRecipient() public {
        PoolKey memory ethKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, 3000, 1, IHooks(address(hook)));
        vm.prank(alice);
        (uint64 groupId, uint256 shares) =
            hook.deposit{value: 1e18}(ethKey, 100, 0, true, 1e18, 0, alice, block.timestamp);

        ReentrantRecipient recipient = new ReentrantRecipient();
        recipient.arm(address(hook), abi.encodeCall(TickTockHook.flipLevel, (plainKey, 100)));
        vm.prank(alice);
        hook.withdraw(groupId, shares, address(recipient), block.timestamp);

        assertTrue(recipient.reentered());
        assertFalse(recipient.reentrySucceeded());
        assertEq(recipient.reentryResult(), _reentrancyError());
        assertApproxEqAbs(address(recipient).balance, 1e18, 2, "the withdrawal still paid");
    }
}
