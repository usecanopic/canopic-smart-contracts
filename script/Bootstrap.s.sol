// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {OracleVault} from "../src/venue/OracleVault.sol";
import {SwapRouter} from "../src/venue/SwapRouter.sol";
import {VaultFactory} from "../src/venue/VaultFactory.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockERC20, MockStockToken, MockPriceFeed} from "../src/mocks/Mocks.sol";

/// @title Bootstrap
/// @notice Gives a newly deployed testnet something to show. It mints mock balances, seeds the launch vault with
///         a 50/50 deposit, then routes a buy and a sell through the SwapRouter so real fills appear in the explorer.
///         DeployProtocol already attested the deployer as LP and trader, so that one account fills both parts.
/// @dev Loads the addresses that script/DeployProtocol.s.sol saved to deployments/<chainId>.json. Run with:
///        forge script script/Bootstrap.s.sol:Bootstrap --broadcast --rpc-url robinhood_testnet
contract Bootstrap is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        MockERC20 usdg = MockERC20(vm.parseJsonAddress(json, ".USDG"));
        MockStockToken stock = MockStockToken(vm.parseJsonAddress(json, ".StockToken"));
        MockPriceFeed feed = MockPriceFeed(vm.parseJsonAddress(json, ".StockFeed"));
        OracleVault vault = OracleVault(vm.parseJsonAddress(json, ".OracleVault"));
        SwapRouter router = SwapRouter(vm.parseJsonAddress(json, ".SwapRouter"));

        vm.startBroadcast(pk);

        // Push a fresh round so the price is not stale, then mint the balances needed for the deposit and the swaps.
        feed.set(feed.answer());
        uint256 mid = uint256(feed.answer()) / 100; // converts the 8-decimal feed price to 6-decimal quote units
        usdg.mint(me, 1_500_000e6);
        stock.mint(me, 1_000_000e6 * 1e18 / mid);

        // Balanced deposit: 500,000 USDG alongside stock tokens worth an equal amount.
        usdg.approve(address(vault), type(uint256).max);
        stock.approve(address(vault), type(uint256).max);
        vault.deposit(500_000e6, 500_000e6 * 1e18 / mid, 0, me);

        // One buy and one sell via the SwapRouter, so trades exist on both sides of the book.
        usdg.approve(address(router), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        Types.MakerQuote memory none;
        router.swapExactIn(
            SwapRouter.SwapParams({
                tokenIn: address(usdg),
                tokenOut: address(stock),
                amountIn: 10_000e6,
                minAmountOut: 0,
                to: address(0),
                deadline: block.timestamp + 10 minutes,
                quote: none,
                quoteSig: ""
            })
        );
        router.swapExactIn(
            SwapRouter.SwapParams({
                tokenIn: address(stock),
                tokenOut: address(usdg),
                amountIn: 20e18,
                minAmountOut: 0,
                to: address(0),
                deadline: block.timestamp + 10 minutes,
                quote: none,
                quoteSig: ""
            })
        );

        vm.stopBroadcast();

        console2.log("Vault bootstrapped", address(vault));
        console2.log("Total vault value in quote units", vault.totalValue());
    }
}
