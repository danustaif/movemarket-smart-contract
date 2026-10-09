// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILiveMarket} from "./interfaces/ILiveMarket.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";
import {IERC165} from "./interfaces/IERC165.sol";
import "./interfaces/LiveMarketTypes.sol";

/// @title LiveMarket
/// @notice Pasar prediksi parimutuel per rentang ply partai catur Lichess, diselesaikan oleh report Chainlink CRE.
/// @dev Spesifikasi: source/docs/CONTRACTS.md. ABI wajib sama dengan source/sot/abi.json (script/check-abi.mjs).
contract LiveMarket is ILiveMarket, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    address public immutable token;
    address public forwarder;
    address public resolver;
    // Nilai awal: sot/constants.json contract.defaults
    uint16 public feeBps = 200;
    uint128 public minBet = 1e6;
    uint128 public maxStakePerUser = 100e6;
    uint256 public nextMarketId = 1;
    uint256 public feesAccrued;

    // internal supaya tidak ada getter di luar sot/abi.json; akses lewat getMarket/getPosition
    mapping(uint256 => Market) internal _markets;
    mapping(uint256 => mapping(address => Position)) internal _positions;
    mapping(bytes32 => string) public gameRefOf;

    modifier onlyResolver() {
        if (msg.sender != resolver) revert NotResolver();
        _;
    }

    constructor(IERC20 token_, address forwarder_, address resolver_) Ownable(msg.sender) {
        token = address(token_);
        forwarder = forwarder_;
        resolver = resolver_;
    }

    // ------------------------------------------------------------------ resolver

    function createMarkets(MarketParams[] calldata p) external onlyResolver whenNotPaused returns (uint256 firstId) {
        uint256 n = p.length;
        if (n == 0 || n > MAX_CREATE_BATCH) revert BadBatch();
        firstId = nextMarketId;
        for (uint256 i; i < n; i++) {
            MarketParams calldata q = p[i];
            uint256 refLen = bytes(q.gameRef).length;
            // Urutan cek penting: toPly >= fromPly sebelum pengurangan, lockTime dibatasi sebelum penjumlahan.
            if (
                refLen == 0 || refLen > MAX_GAMEREF_BYTES || q.fromPly < 1 || q.toPly < q.fromPly
                    || q.toPly - q.fromPly >= MAX_WINDOW_PLIES || q.lockTime <= block.timestamp
                    || q.lockTime > block.timestamp + MAX_BET_WINDOW_SEC || q.resolveDeadline <= q.lockTime
                    || q.resolveDeadline > q.lockTime + MAX_RESOLVE_DELAY_SEC
                    || (q.marketType == MarketType.CASTLE && q.side == Side.ANY)
            ) revert InvalidParams(i);

            uint256 id = firstId + i;
            bytes32 gameKey = keccak256(bytes(q.gameRef));
            Market storage m = _markets[id];
            m.gameKey = gameKey;
            m.marketType = q.marketType;
            m.side = q.side;
            m.fromPly = q.fromPly;
            m.toPly = q.toPly;
            m.lockTime = q.lockTime;
            m.resolveDeadline = q.resolveDeadline;
            if (bytes(gameRefOf[gameKey]).length == 0) gameRefOf[gameKey] = q.gameRef;
            emit MarketCreated(
                id, gameKey, q.gameRef, uint8(q.marketType), uint8(q.side), q.fromPly, q.toPly, q.lockTime,
                q.resolveDeadline
            );
        }
        nextMarketId = firstId + n;
    }

    function lockMarkets(uint256[] calldata ids) external onlyResolver {
        uint256 n = ids.length;
        if (n == 0 || n > MAX_LOCK_BATCH) revert BadBatch();
        for (uint256 i; i < n; i++) {
            Market storage m = _markets[ids[i]];
            // Pasar yang tidak ada punya lockTime 0, jadi ikut terlewati oleh cek waktu.
            if (m.status == Status.OPEN && block.timestamp < m.lockTime) {
                m.lockTime = uint64(block.timestamp);
                emit MarketLocked(ids[i], m.lockTime);
            }
        }
    }

    function requestResolution(string calldata gameRef, uint256[] calldata ids) external onlyResolver {}

    // ------------------------------------------------------------------ pengguna

    function bet(uint256 id, bool yes, uint128 amount) external nonReentrant whenNotPaused {
        Market storage m = _markets[id];
        if (!_exists(id) || m.status != Status.OPEN) revert MarketNotOpen(id);
        if (block.timestamp >= m.lockTime) revert BettingClosed(id);
        if (amount < minBet) revert AmountTooSmall();
        Position storage pos = _positions[id][msg.sender];
        if (uint256(pos.yes) + pos.no + amount > maxStakePerUser) revert StakeCapExceeded();

        if (yes) {
            m.poolYes += amount;
            pos.yes += amount;
        } else {
            m.poolNo += amount;
            pos.no += amount;
        }
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit BetPlaced(id, msg.sender, yes, amount, m.poolYes, m.poolNo);
    }

    function claim(uint256 id) external nonReentrant returns (uint256 payout) {}

    function claimMany(uint256[] calldata ids) external nonReentrant returns (uint256 totalPayout) {}

    function refund(uint256 id) external nonReentrant returns (uint256 amount) {}

    // ------------------------------------------------------------------ CRE

    function onReport(bytes calldata, bytes calldata report) external override {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {}

    // ------------------------------------------------------------------ owner

    function adminVoid(uint256[] calldata ids) external onlyOwner {
        for (uint256 i; i < ids.length; i++) {
            if (!_exists(ids[i]) || _markets[ids[i]].status != Status.OPEN) revert MarketNotOpen(ids[i]);
            _void(ids[i], VOID_ADMIN);
        }
    }

    function setForwarder(address forwarder_) external onlyOwner {}

    function setResolver(address resolver_) external onlyOwner {}

    function setFeeBps(uint16 feeBps_) external onlyOwner {}

    function setLimits(uint128 minBet_, uint128 maxStakePerUser_) external onlyOwner {}

    function withdrawFees(address to) external onlyOwner {}

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------ view

    function getMarket(uint256 id) external view returns (Market memory) {
        return _markets[id];
    }

    function getMarkets(uint256[] calldata ids) external view returns (MarketView[] memory) {}

    function getPosition(uint256 id, address user) external view returns (Position memory) {
        return _positions[id][user];
    }

    function claimable(uint256 id, address user) external view returns (uint256) {}

    function refundable(uint256 id, address user) external view returns (uint256) {}

    // ------------------------------------------------------------------ internal

    function _exists(uint256 id) private view returns (bool) {
        return id != 0 && id < nextMarketId;
    }

    function _void(uint256 id, uint8 reason) private {
        Market storage m = _markets[id];
        m.status = Status.VOIDED;
        m.outcome = Outcome.VOID;
        emit MarketVoided(id, reason);
    }
}
