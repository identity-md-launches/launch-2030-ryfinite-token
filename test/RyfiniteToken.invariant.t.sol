// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RyfiniteToken} from "../src/RyfiniteToken.sol";

/// @dev Confines token ownership to four actors, so the invariant can enumerate every balance.
contract RyfiniteTokenHandler is Test {
    RyfiniteToken internal immutable token;
    address[4] internal actors;

    constructor(RyfiniteToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function spend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowanceBefore = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        amount = bound(amount, 0, balance < allowanceBefore ? balance : allowanceBefore);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        uint256 expectedAllowance = allowanceBefore == type(uint256).max ? allowanceBefore : allowanceBefore - amount;
        assertEq(token.allowance(owner, spender), expectedAllowance);
    }
}

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

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RyfiniteTokenHandler.move.selector;
        selectors[1] = RyfiniteTokenHandler.approve.selector;
        selectors[2] = RyfiniteTokenHandler.spend.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
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
