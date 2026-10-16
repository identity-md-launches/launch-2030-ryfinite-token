// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RyfiniteToken} from "../src/RyfiniteToken.sol";

/// @dev Confines token ownership to four actors, so the invariant can enumerate every balance.
contract RyfiniteTokenHandler is Test {
    RyfiniteToken internal immutable token;
    address[4] internal actors;
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    // Independent ledger: initialized from the specified allocation and updated only
    // from successful requests, never copied from balanceOf/allowance responses.
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(RyfiniteToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = SUPPLY / actors.length;
        }
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, uint8 mode) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        // Explicitly exercise revocation, infinite approval, and small finite
        // approvals; arbitrary uint256 approvals remain reachable as well.
        if (mode % 4 == 0) amount = 0;
        else if (mode % 4 == 1) amount = type(uint256).max;
        else if (mode % 4 == 2) amount = bound(amount, 0, expectedBalance[owner]);
        _approve(owner, spender, amount);
    }

    function spend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowanceBefore = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        amount = bound(amount, 0, balance < allowanceBefore ? balance : allowanceBefore);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        uint256 allowanceAfter = allowanceBefore == type(uint256).max ? allowanceBefore : allowanceBefore - amount;
        _recordTransfer(owner, to, amount);
        _recordAllowance(owner, spender, allowanceAfter);
    }

    /// @dev Mix rejected calls into the same sequences as transfers, approvals and
    /// revocations. The ledger stays unchanged by each rejected operation, so the
    /// invariants also check rollback and unrelated accounts/allowances.
    function rejectCall(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount, uint8 kind) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        kind %= 6;

        if (kind == 0) {
            uint256 balance = expectedBalance[owner];
            amount = bound(amount, balance + 1, type(uint256).max);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
            vm.prank(owner);
            token.transfer(to, amount);
        } else if (kind == 1) {
            uint256 approval = bound(amount, 0, SUPPLY);
            _approve(owner, spender, approval);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, spender, approval, approval + 1
                )
            );
            vm.prank(spender);
            token.transferFrom(owner, to, approval + 1);
        } else if (kind == 2) {
            uint256 balance = expectedBalance[owner];
            amount = bound(amount, balance + 1, type(uint256).max);
            _approve(owner, spender, amount);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
            vm.prank(spender);
            token.transferFrom(owner, to, amount);
        } else if (kind == 3) {
            amount = bound(amount, 0, expectedBalance[owner]);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(owner);
            token.transfer(address(0), amount);
        } else if (kind == 4) {
            amount = bound(amount, 0, expectedBalance[owner]);
            _approve(owner, spender, amount);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(spender);
            token.transferFrom(owner, address(0), amount);
        } else {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            vm.prank(owner);
            token.approve(address(0), amount);
        }
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        _recordAllowance(owner, spender, amount);
    }

    function _recordAllowance(address owner, address spender, uint256 amount) internal {
        expectedAllowance[owner][spender] = amount;
        assertEq(token.allowance(owner, spender), amount, "incorrect allowance transition");
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        // Includes self-transfers, for which the net ledger change is zero.
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        assertEq(token.balanceOf(from), expectedBalance[from], "incorrect debit");
        assertEq(token.balanceOf(to), expectedBalance[to], "incorrect credit");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract RyfiniteTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    RyfiniteToken internal token;
    RyfiniteTokenHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        actors = [makeAddr("holder 0"), makeAddr("holder 1"), makeAddr("holder 2"), makeAddr("holder 3")];
        vm.prank(actors[0]);
        token = new RyfiniteToken();
        vm.startPrank(actors[0]);
        for (uint256 i = 1; i < actors.length; ++i) {
            token.transfer(actors[i], SUPPLY / actors.length);
        }
        vm.stopPrank();
        handler = new RyfiniteTokenHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = RyfiniteTokenHandler.move.selector;
        selectors[1] = RyfiniteTokenHandler.approve.selector;
        selectors[2] = RyfiniteTokenHandler.spend.selector;
        selectors[3] = RyfiniteTokenHandler.rejectCall.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_eachBalanceAndAllowanceMatchesAuthorizedOperations() public view {
        for (uint256 i; i < actors.length; ++i) {
            address owner = actors[i];
            assertEq(token.balanceOf(owner), handler.expectedBalance(owner), "actor balance diverged");
            for (uint256 j; j < actors.length; ++j) {
                address spender = actors[j];
                assertEq(
                    token.allowance(owner, spender), handler.expectedAllowance(owner, spender), "allowance diverged"
                );
            }
            assertEq(token.allowance(owner, address(0)), 0);
        }
    }

    function invariant_supplyIsFixedAndFullyAccountedFor() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariant_metadataRemainsUnchanged() public view {
        assertEq(token.name(), "Ryfinite Token");
        assertEq(token.symbol(), "RFN");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }
}
