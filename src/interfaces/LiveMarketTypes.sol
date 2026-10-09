// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Enum dan konstanta LiveMarket. Nilai dan urutan mengikuti sot/constants.json
// (enums, contract). Jangan ubah urutan enum: nilainya dipakai sebagai uint8 di
// event, report CRE, indexer, resolver, dan frontend.

enum MarketType { CHECK, CAPTURE, CASTLE }      // 0, 1, 2
enum Side { ANY, WHITE, BLACK }                 // 0, 1, 2
enum Status { OPEN, RESOLVED, VOIDED }          // 0, 1, 2
enum Outcome { NONE, YES, NO, VOID }            // 0, 1, 2, 3

// Alasan void (event MarketVoided)
uint8 constant VOID_ORACLE = 1;
uint8 constant VOID_NO_WINNERS = 2;
uint8 constant VOID_ADMIN = 3;
uint8 constant VOID_EXPIRED = 4;

// Alasan skip (event ResolutionSkipped)
uint8 constant SKIP_MARKET_NOT_FOUND = 1;
uint8 constant SKIP_GAME_MISMATCH = 2;
uint8 constant SKIP_NOT_OPEN = 3;
uint8 constant SKIP_NOT_LOCKED = 4;
uint8 constant SKIP_BAD_OUTCOME = 5;

uint256 constant MAX_CREATE_BATCH = 20;
uint256 constant MAX_RESOLVE_BATCH = 40;
uint256 constant MAX_LOCK_BATCH = 40;
uint16 constant MAX_WINDOW_PLIES = 40;
uint64 constant MAX_BET_WINDOW_SEC = 600;
uint64 constant MAX_RESOLVE_DELAY_SEC = 43200;
uint16 constant MAX_FEE_BPS = 500;
uint256 constant MAX_GAMEREF_BYTES = 96;
