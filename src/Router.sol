// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IPoolToken.sol";
import "./interfaces/IBorrowable.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/ICollateral.sol";
import "./interfaces/IImpermaxCallee.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./libraries/UniswapV2Library.sol";

contract Router is IRouter, IImpermaxCallee {
    using SafeTransferLib for address;

    address public immutable override factory;
    address public immutable override WETH;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "ImpermaxRouter: EXPIRED");
        _;
    }

    modifier checkETH(address poolToken) {
        require(
            WETH == IPoolToken(poolToken).underlying(),
            "ImpermaxRouter: NOT_WETH"
        );
        _;
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    /*** Mint ***/

    function _mint(
        address poolToken,
        address token,
        uint amount,
        address from,
        address to
    ) internal virtual returns (uint tokens) {
        if (from == address(this)) token.safeTransfer(poolToken, amount);
        else token.safeTransferFrom(from, poolToken, amount);
        tokens = IPoolToken(poolToken).mint(to);
    }

    function mint(
        address poolToken,
        uint amount,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint tokens) {
        return
            _mint(
                poolToken,
                IPoolToken(poolToken).underlying(),
                amount,
                msg.sender,
                to
            );
    }

    function mintETH(
        address poolToken,
        address to,
        uint deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        checkETH(poolToken)
        returns (uint tokens)
    {
        IWETH(WETH).deposit{value: msg.value}();
        return _mint(poolToken, WETH, msg.value, address(this), to);
    }

    function mintCollateral(
        address poolToken,
        uint amount,
        address to,
        uint deadline,
        bytes calldata permitData
    ) external virtual override ensure(deadline) returns (uint tokens) {
        address underlying = IPoolToken(poolToken).underlying();
        if (isStakedLPToken(underlying)) {
            address uniswapV2Pair = IStakedLPToken01(underlying).underlying();
            _permit(uniswapV2Pair, amount, deadline, permitData);
            uniswapV2Pair.safeTransferFrom(msg.sender, underlying, amount);
            IStakedLPToken01(underlying).mint(poolToken);
            return IPoolToken(poolToken).mint(to);
        } else {
            _permit(underlying, amount, deadline, permitData);
            return _mint(poolToken, underlying, amount, msg.sender, to);
        }
    }

    /*** Redeem ***/

    function redeem(
        address poolToken,
        uint tokens,
        address to,
        uint deadline,
        bytes memory permitData
    ) public virtual override ensure(deadline) returns (uint amount) {
        _permit(poolToken, tokens, deadline, permitData);
        uint tokensBalance = IERC20(poolToken).balanceOf(msg.sender);
        tokens = tokens < tokensBalance ? tokens : tokensBalance;
        IPoolToken(poolToken).transferFrom(msg.sender, poolToken, tokens);
        address underlying = IPoolToken(poolToken).underlying();
        if (isStakedLPToken(underlying)) {
            IPoolToken(poolToken).redeem(underlying);
            return IStakedLPToken01(underlying).redeem(to);
        } else {
            return IPoolToken(poolToken).redeem(to);
        }
    }

    function redeemETH(
        address poolToken,
        uint tokens,
        address to,
        uint deadline,
        bytes memory permitData
    )
        public
        virtual
        override
        ensure(deadline)
        checkETH(poolToken)
        returns (uint amountETH)
    {
        _permit(poolToken, tokens, deadline, permitData);
        uint tokensBalance = IERC20(poolToken).balanceOf(msg.sender);
        tokens = tokens < tokensBalance ? tokens : tokensBalance;
        IPoolToken(poolToken).transferFrom(msg.sender, poolToken, tokens);
        amountETH = IPoolToken(poolToken).redeem(address(this));
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /*** Borrow ***/

    function borrow(
        address borrowable,
        uint amount,
        address to,
        uint deadline,
        bytes memory permitData
    ) public virtual override ensure(deadline) {
        _borrowPermit(borrowable, amount, deadline, permitData);
        IBorrowable(borrowable).borrow(msg.sender, to, amount, new bytes(0));
    }

    function borrowETH(
        address borrowable,
        uint amountETH,
        address to,
        uint deadline,
        bytes memory permitData
    ) public virtual override ensure(deadline) checkETH(borrowable) {
        borrow(borrowable, amountETH, address(this), deadline, permitData);
        IWETH(WETH).withdraw(amountETH);
        to.safeTransferETH(amountETH);
    }

    /*** Repay ***/

    function _repayAmount(
        address borrowable,
        uint amountMax,
        address borrower
    ) internal virtual returns (uint amount) {
        IBorrowable(borrowable).accrueInterest();
        uint borrowedAmount = IBorrowable(borrowable).borrowBalance(borrower);
        amount = amountMax < borrowedAmount ? amountMax : borrowedAmount;
    }

    function repay(
        address borrowable,
        uint amountMax,
        address borrower,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amount) {
        amount = _repayAmount(borrowable, amountMax, borrower);
        IBorrowable(borrowable).underlying().safeTransferFrom(
            msg.sender,
            borrowable,
            amount
        );
        IBorrowable(borrowable).borrow(borrower, address(0), 0, new bytes(0));
    }

    function repayETH(
        address borrowable,
        address borrower,
        uint deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        checkETH(borrowable)
        returns (uint amountETH)
    {
        amountETH = _repayAmount(borrowable, msg.value, borrower);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(borrowable, amountETH));
        IBorrowable(borrowable).borrow(borrower, address(0), 0, new bytes(0));
        // refund surpluss eth, if any
        if (msg.value > amountETH)
            msg.sender.safeTransferETH(msg.value - amountETH);
    }

    /*** Liquidate ***/

    function liquidate(
        address borrowable,
        uint amountMax,
        address borrower,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
        returns (uint amount, uint seizeTokens)
    {
        amount = _repayAmount(borrowable, amountMax, borrower);
        IBorrowable(borrowable).underlying().safeTransferFrom(
            msg.sender,
            borrowable,
            amount
        );
        seizeTokens = IBorrowable(borrowable).liquidate(borrower, to);
    }

    function liquidateETH(
        address borrowable,
        address borrower,
        address to,
        uint deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        checkETH(borrowable)
        returns (uint amountETH, uint seizeTokens)
    {
        amountETH = _repayAmount(borrowable, msg.value, borrower);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(borrowable, amountETH));
        seizeTokens = IBorrowable(borrowable).liquidate(borrower, to);
        // refund surpluss eth, if any
        if (msg.value > amountETH)
            msg.sender.safeTransferETH(msg.value - amountETH);
    }

    /*** Leverage LP Token ***/

    function _leverage(
        address underlying,
        uint amountA,
        uint amountB,
        address to
    ) internal virtual {
        address borrowableA = getBorrowable(underlying, 0);
        // mint collateral
        bytes memory borrowBData = abi.encode(
            CalleeData({
                callType: CallType.ADD_LIQUIDITY_AND_MINT,
                underlying: underlying,
                borrowableIndex: 1,
                data: abi.encode(
                    AddLiquidityAndMintCalldata({
                        amountA: amountA,
                        amountB: amountB,
                        to: to
                    })
                )
            })
        );
        // borrow borrowableB
        bytes memory borrowAData = abi.encode(
            CalleeData({
                callType: CallType.BORROWB,
                underlying: underlying,
                borrowableIndex: 0,
                data: abi.encode(
                    BorrowBCalldata({
                        borrower: msg.sender,
                        receiver: address(this),
                        borrowAmount: amountB,
                        data: borrowBData
                    })
                )
            })
        );
        // borrow borrowableA
        IBorrowable(borrowableA).borrow(
            msg.sender,
            address(this),
            amountA,
            borrowAData
        );
    }

    function leverage(
        address underlying,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bytes calldata permitDataA,
        bytes calldata permitDataB
    ) external virtual override ensure(deadline) {
        _borrowPermit(
            getBorrowable(underlying, 0),
            amountADesired,
            deadline,
            permitDataA
        );
        _borrowPermit(
            getBorrowable(underlying, 1),
            amountBDesired,
            deadline,
            permitDataB
        );
        address uniswapV2Pair = getUniswapV2Pair(underlying);
        (uint amountA, uint amountB) = _optimalLiquidity(
            uniswapV2Pair,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        _leverage(underlying, amountA, amountB, to);
    }

    function _addLiquidityAndMint(
        address underlying,
        uint amountA,
        uint amountB,
        address to
    ) internal virtual {
        (
            address collateral,
            address borrowableA,
            address borrowableB
        ) = getLendingPool(underlying);
        address uniswapV2Pair = getUniswapV2Pair(underlying);
        // add liquidity to uniswap pair
        IBorrowable(borrowableA).underlying().safeTransfer(
            uniswapV2Pair,
            amountA
        );
        IBorrowable(borrowableB).underlying().safeTransfer(
            uniswapV2Pair,
            amountB
        );
        // mint LP token
        if (isStakedLPToken(underlying))
            IUniswapV2Pair(uniswapV2Pair).mint(underlying);
        IUniswapV2Pair(underlying).mint(collateral);
        // mint collateral
        ICollateral(collateral).mint(to);
    }

    /*** Deleverage LP Token ***/

    function deleverage(
        address underlying,
        uint redeemTokens,
        uint amountAMin,
        uint amountBMin,
        uint deadline,
        bytes calldata permitData
    ) external virtual override ensure(deadline) {
        address collateral = getCollateral(underlying);
        _permit(collateral, redeemTokens, deadline, permitData);
        uint tokensBalance = IERC20(collateral).balanceOf(msg.sender);
        redeemTokens = redeemTokens < tokensBalance
            ? redeemTokens
            : tokensBalance;
        require(redeemTokens > 0, "ImpermaxRouter: REDEEM_ZERO");
        uint exchangeRate = ICollateral(collateral).exchangeRate();
        uint redeemAmount = (((redeemTokens - 1) * exchangeRate) / 1e18);
        bytes memory redeemData = abi.encode(
            CalleeData({
                callType: CallType.REMOVE_LIQ_AND_REPAY,
                underlying: underlying,
                borrowableIndex: 0,
                data: abi.encode(
                    RemoveLiqAndRepayCalldata({
                        borrower: msg.sender,
                        redeemTokens: redeemTokens,
                        redeemAmount: redeemAmount,
                        amountAMin: amountAMin,
                        amountBMin: amountBMin
                    })
                )
            })
        );
        // flashRedeem
        ICollateral(collateral).flashRedeem(
            address(this),
            redeemAmount,
            redeemData
        );
    }

    function _removeLiqAndRepay(
        address underlying,
        address borrower,
        uint redeemTokens,
        uint redeemAmount,
        uint amountAMin,
        uint amountBMin
    ) internal virtual {
        (
            address collateral,
            address borrowableA,
            address borrowableB
        ) = getLendingPool(underlying);
        address tokenA = IBorrowable(borrowableA).underlying();
        address tokenB = IBorrowable(borrowableB).underlying();
        address uniswapV2Pair = getUniswapV2Pair(underlying);
        // removeLiquidity
        IUniswapV2Pair(underlying).transfer(underlying, redeemAmount);
        //TransferHelper.safeTransfer(underlying, underlying, redeemAmount);
        if (isStakedLPToken(underlying))
            IStakedLPToken01(underlying).redeem(uniswapV2Pair);
        (uint amountAMax, uint amountBMax) = IUniswapV2Pair(uniswapV2Pair).burn(
            address(this)
        );
        require(
            amountAMax >= amountAMin,
            "ImpermaxRouter: INSUFFICIENT_A_AMOUNT"
        );
        require(
            amountBMax >= amountBMin,
            "ImpermaxRouter: INSUFFICIENT_B_AMOUNT"
        );
        // repay and refund
        _repayAndRefund(borrowableA, tokenA, borrower, amountAMax);
        _repayAndRefund(borrowableB, tokenB, borrower, amountBMax);
        // repay flash redeem
        ICollateral(collateral).transferFrom(
            borrower,
            collateral,
            redeemTokens
        );
    }

    function _repayAndRefund(
        address borrowable,
        address token,
        address borrower,
        uint amountMax
    ) internal virtual {
        //repay
        uint amount = _repayAmount(borrowable, amountMax, borrower);
        token.safeTransfer(borrowable, amount);
        IBorrowable(borrowable).borrow(borrower, address(0), 0, new bytes(0));
        // refund excess
        if (amountMax > amount) {
            uint refundAmount = amountMax - amount;
            if (token == WETH) {
                IWETH(WETH).withdraw(refundAmount);
                borrower.safeTransferETH(refundAmount);
            } else token.safeTransfer(borrower, refundAmount);
        }
    }

    /*** Impermax Callee ***/

    enum CallType {
        ADD_LIQUIDITY_AND_MINT,
        BORROWB,
        REMOVE_LIQ_AND_REPAY
    }
    struct CalleeData {
        CallType callType;
        address underlying;
        uint8 borrowableIndex;
        bytes data;
    }
    struct AddLiquidityAndMintCalldata {
        uint amountA;
        uint amountB;
        address to;
    }
    struct BorrowBCalldata {
        address borrower;
        address receiver;
        uint borrowAmount;
        bytes data;
    }
    struct RemoveLiqAndRepayCalldata {
        address borrower;
        uint redeemTokens;
        uint redeemAmount;
        uint amountAMin;
        uint amountBMin;
    }

    function impermaxBorrow(
        address sender,
        address borrower,
        uint borrowAmount,
        bytes calldata data
    ) external virtual override {
        borrower;
        borrowAmount;
        CalleeData memory calleeData = abi.decode(data, (CalleeData));
        address declaredCaller = getBorrowable(
            calleeData.underlying,
            calleeData.borrowableIndex
        );
        // only succeeds if called by a borrowable and if that borrowable has been called by the router
        require(sender == address(this), "ImpermaxRouter: SENDER_NOT_ROUTER");
        require(
            msg.sender == declaredCaller,
            "ImpermaxRouter: UNAUTHORIZED_CALLER"
        );
        if (calleeData.callType == CallType.ADD_LIQUIDITY_AND_MINT) {
            AddLiquidityAndMintCalldata memory d = abi.decode(
                calleeData.data,
                (AddLiquidityAndMintCalldata)
            );
            _addLiquidityAndMint(
                calleeData.underlying,
                d.amountA,
                d.amountB,
                d.to
            );
        } else if (calleeData.callType == CallType.BORROWB) {
            BorrowBCalldata memory d = abi.decode(
                calleeData.data,
                (BorrowBCalldata)
            );
            address borrowableB = getBorrowable(calleeData.underlying, 1);
            IBorrowable(borrowableB).borrow(
                d.borrower,
                d.receiver,
                d.borrowAmount,
                d.data
            );
        } else revert();
    }

    function impermaxRedeem(
        address sender,
        uint redeemAmount,
        bytes calldata data
    ) external virtual override {
        redeemAmount;
        CalleeData memory calleeData = abi.decode(data, (CalleeData));
        address declaredCaller = getCollateral(calleeData.underlying);
        // only succeeds if called by a collateral and if that collateral has been called by the router
        require(sender == address(this), "ImpermaxRouter: SENDER_NOT_ROUTER");
        require(
            msg.sender == declaredCaller,
            "ImpermaxRouter: UNAUTHORIZED_CALLER"
        );
        if (calleeData.callType == CallType.REMOVE_LIQ_AND_REPAY) {
            RemoveLiqAndRepayCalldata memory d = abi.decode(
                calleeData.data,
                (RemoveLiqAndRepayCalldata)
            );
            _removeLiqAndRepay(
                calleeData.underlying,
                d.borrower,
                d.redeemTokens,
                d.redeemAmount,
                d.amountAMin,
                d.amountBMin
            );
        } else revert();
    }

    /*** Utilities ***/

    function _permit(
        address poolToken,
        uint amount,
        uint deadline,
        bytes memory permitData
    ) internal virtual {
        if (permitData.length == 0) return;
        (bool approveMax, uint8 v, bytes32 r, bytes32 s) = abi.decode(
            permitData,
            (bool, uint8, bytes32, bytes32)
        );
        uint value = approveMax ? uint(-1) : amount;
        IPoolToken(poolToken).permit(
            msg.sender,
            address(this),
            value,
            deadline,
            v,
            r,
            s
        );
    }

    function _borrowPermit(
        address borrowable,
        uint amount,
        uint deadline,
        bytes memory permitData
    ) internal virtual {
        if (permitData.length == 0) return;
        (bool approveMax, uint8 v, bytes32 r, bytes32 s) = abi.decode(
            permitData,
            (bool, uint8, bytes32, bytes32)
        );
        uint value = approveMax ? uint(-1) : amount;
        IBorrowable(borrowable).borrowPermit(
            msg.sender,
            address(this),
            value,
            deadline,
            v,
            r,
            s
        );
    }

    function _optimalLiquidity(
        address uniswapV2Pair,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) public view virtual returns (uint amountA, uint amountB) {
        (uint reserveA, uint reserveB, ) = IUniswapV2Pair(uniswapV2Pair)
            .getReserves();
        uint amountBOptimal = UniswapV2Library.quote(
            amountADesired,
            reserveA,
            reserveB
        );
        if (amountBOptimal <= amountBDesired) {
            require(
                amountBOptimal >= amountBMin,
                "ImpermaxRouter: INSUFFICIENT_B_AMOUNT"
            );
            (amountA, amountB) = (amountADesired, amountBOptimal);
        } else {
            uint amountAOptimal = UniswapV2Library.quote(
                amountBDesired,
                reserveB,
                reserveA
            );
            assert(amountAOptimal <= amountADesired);
            require(
                amountAOptimal >= amountAMin,
                "ImpermaxRouter: INSUFFICIENT_A_AMOUNT"
            );
            (amountA, amountB) = (amountAOptimal, amountBDesired);
        }
    }

    function isStakedLPToken(
        address underlying
    ) public view virtual override returns (bool) {
        try IStakedLPToken01(underlying).isStakedLPToken() returns (
            bool result
        ) {
            return result;
        } catch {
            return false;
        }
    }

    function getUniswapV2Pair(
        address underlying
    ) public view virtual override returns (address) {
        try IStakedLPToken01(underlying).underlying() returns (address u) {
            if (u != address(0)) return u;
            return underlying;
        } catch {
            return underlying;
        }
    }

    function getBorrowable(
        address underlying,
        uint8 index
    ) public view virtual override returns (address borrowable) {
        require(index < 2, "ImpermaxRouter: INDEX_TOO_HIGH");
        (, , , address borrowable0, address borrowable1) = IFactory(factory)
            .getLendingPool(underlying);
        return index == 0 ? borrowable0 : borrowable1;
    }

    function getCollateral(
        address underlying
    ) public view virtual override returns (address collateral) {
        (, , collateral, , ) = IFactory(factory).getLendingPool(underlying);
    }

    function getLendingPool(
        address underlying
    )
        public
        view
        virtual
        override
        returns (address collateral, address borrowableA, address borrowableB)
    {
        collateral = getCollateral(underlying);
        borrowableA = getBorrowable(underlying, 0);
        borrowableB = getBorrowable(underlying, 1);
    }
}
