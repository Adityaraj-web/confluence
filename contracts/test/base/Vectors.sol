// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @notice Loads the JSON vectors that `reference/gen_vectors.py` writes to `test/vectors/` (V2-00).
/// @dev Uses `vm.readFile` and `vm.parseJson*` only, so CI needs no FFI. Big integers are decimal strings in the
///      files. Index 0 of every venue list is the pool. Needs `fs_permissions` read access to `test/vectors`.
library Vectors {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant DIR = "test/vectors/";

    // Names of the files the generator writes.
    string internal constant SPLIT_2V = "split_2v.json";
    string internal constant SPLIT_3V = "split_3v.json";
    string internal constant SPLIT_CAPS = "split_caps.json";
    string internal constant POOL_CROSSING = "pool_crossing.json";
    string internal constant V1_DEMO = "v1_demo.json";

    /// @dev A constant-product venue. `cap` is type(uint256).max when there is none.
    struct VenueV {
        uint256 x;
        uint256 y;
        uint32 feeE9;
        uint256 cap;
    }

    /// @dev One split case. `perVenue` is the output of each venue for exact input, the input for exact output.
    struct Split {
        string name;
        bool exactIn;
        uint256 amount;
        VenueV[] venues;
        uint256[] alloc;
        uint256[] perVenue;
        uint256 totalInt;
    }

    struct PoolV {
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int24 tick;
        uint24 feePips;
        int24 tickSpacing;
        bool zeroForOne;
        int24[] ticks;
        int128[] liquidityNets;
    }

    /// @dev One tick range of the pool as a venue in the swap's direction.
    struct Seg {
        uint256 x;
        uint256 y;
        uint32 feeE9;
        uint256 capIn;
        uint256 capOut;
        uint128 liquidity;
    }

    /// @dev A pool whose ranges are crossed, plus one maker.
    struct Crossing {
        string name;
        bool exactIn;
        uint256 amount;
        PoolV pool;
        Seg[] segments;
        VenueV maker;
        uint256 allocPool;
        uint256 allocMaker;
        uint256 poolLeg;
        uint256 makerLeg;
        uint256 rangesCrossed;
        uint256 ticksCrossed;
        uint256 totalInt;
    }

    /// @dev A v1 demo case: the pool, Priya, pool-only and the closed-form split. `hint*` is set on the first case only.
    struct V1Case {
        string name;
        uint256 amount;
        PoolV pool;
        VenueV poolVenue;
        uint256 poolCapIn;
        VenueV priya;
        uint256 poolOnlyOut;
        uint256 allocPool;
        uint256 allocPriya;
        uint256 poolLeg;
        uint256 priyaLeg;
        uint256 totalInt;
        bool hasHint;
        uint256 hint;
        uint256 hintAquaLeg;
        uint256 hintPoolLeg;
        uint256 hintTotal;
    }

    // ------------------------------------------------------------------ files

    /// @notice The raw JSON of `file` (a name from this library).
    function read(string memory file) internal view returns (string memory) {
        return vm.readFile(string.concat(DIR, file));
    }

    /// @notice The `count` field, and the schema check: fails if the file is not a vector file.
    function count(string memory json) internal view returns (uint256 n) {
        require(
            keccak256(bytes(vm.parseJsonString(json, ".schema"))) == keccak256("confluence-vectors/1"),
            "Vectors: unknown schema"
        );
        n = vm.parseJsonUint(json, ".count");
        require(n > 0 && n == _arrayLength(json, ".cases"), "Vectors: count != number of cases");
    }

    // ------------------------------------------------------------------ split files

    function split(string memory json, uint256 i) internal pure returns (Split memory s) {
        string memory p = _case(i);
        s.name = vm.parseJsonString(json, string.concat(p, ".name"));
        s.exactIn = _eq(vm.parseJsonString(json, string.concat(p, ".mode")), "in");
        s.amount = vm.parseJsonUint(json, string.concat(p, ".amount"));
        s.alloc = vm.parseJsonUintArray(json, string.concat(p, ".alloc"));
        s.perVenue = vm.parseJsonUintArray(json, string.concat(p, ".perVenue"));
        s.totalInt = vm.parseJsonUint(json, string.concat(p, ".totalInt"));
        s.venues = new VenueV[](s.alloc.length);
        for (uint256 j; j < s.alloc.length; j++) {
            s.venues[j] = venue(json, string.concat(p, ".venues[", vm.toString(j), "]"));
        }
    }

    function venue(string memory json, string memory path) internal pure returns (VenueV memory v) {
        v.x = vm.parseJsonUint(json, string.concat(path, ".x"));
        v.y = vm.parseJsonUint(json, string.concat(path, ".y"));
        v.feeE9 = uint32(vm.parseJsonUint(json, string.concat(path, ".feeE9")));
        v.cap = vm.parseJsonUint(json, string.concat(path, ".cap"));
    }

    // ------------------------------------------------------------------ pool files

    function pool(string memory json, string memory path) internal view returns (PoolV memory p) {
        p.sqrtPriceX96 = uint160(vm.parseJsonUint(json, string.concat(path, ".sqrtPriceX96")));
        p.liquidity = uint128(vm.parseJsonUint(json, string.concat(path, ".liquidity")));
        p.tick = int24(vm.parseJsonInt(json, string.concat(path, ".tick")));
        p.feePips = uint24(vm.parseJsonUint(json, string.concat(path, ".feePips")));
        p.tickSpacing = int24(vm.parseJsonInt(json, string.concat(path, ".tickSpacing")));
        p.zeroForOne = vm.parseJsonBool(json, string.concat(path, ".zeroForOne"));
        uint256 n = _arrayLength(json, string.concat(path, ".ticks"));
        p.ticks = new int24[](n);
        p.liquidityNets = new int128[](n);
        for (uint256 k; k < n; k++) {
            string memory tp = string.concat(path, ".ticks[", vm.toString(k), "]");
            p.ticks[k] = int24(vm.parseJsonInt(json, string.concat(tp, ".tick")));
            p.liquidityNets[k] = int128(vm.parseJsonInt(json, string.concat(tp, ".liquidityNet")));
        }
    }

    function crossing(string memory json, uint256 i) internal view returns (Crossing memory c) {
        string memory p = _case(i);
        c.name = vm.parseJsonString(json, string.concat(p, ".name"));
        c.exactIn = _eq(vm.parseJsonString(json, string.concat(p, ".mode")), "in");
        c.amount = vm.parseJsonUint(json, string.concat(p, ".amount"));
        c.pool = pool(json, string.concat(p, ".pool"));
        c.maker = venue(json, string.concat(p, ".maker"));
        c.allocPool = vm.parseJsonUint(json, string.concat(p, ".allocPool"));
        c.allocMaker = vm.parseJsonUint(json, string.concat(p, ".allocMaker"));
        c.poolLeg = vm.parseJsonUint(json, string.concat(p, ".poolLeg"));
        c.makerLeg = vm.parseJsonUint(json, string.concat(p, ".makerLeg"));
        c.rangesCrossed = vm.parseJsonUint(json, string.concat(p, ".rangesCrossed"));
        c.ticksCrossed = vm.parseJsonUint(json, string.concat(p, ".ticksCrossed"));
        c.totalInt = vm.parseJsonUint(json, string.concat(p, ".totalInt"));

        uint256 n = _arrayLength(json, string.concat(p, ".segments"));
        c.segments = new Seg[](n);
        for (uint256 k; k < n; k++) {
            string memory sp = string.concat(p, ".segments[", vm.toString(k), "]");
            c.segments[k] = Seg({
                x: vm.parseJsonUint(json, string.concat(sp, ".x")),
                y: vm.parseJsonUint(json, string.concat(sp, ".y")),
                feeE9: uint32(vm.parseJsonUint(json, string.concat(sp, ".feeE9"))),
                capIn: vm.parseJsonUint(json, string.concat(sp, ".capIn")),
                capOut: vm.parseJsonUint(json, string.concat(sp, ".capOut")),
                liquidity: uint128(vm.parseJsonUint(json, string.concat(sp, ".liquidity")))
            });
        }
    }

    function v1Case(string memory json, uint256 i) internal view returns (V1Case memory c) {
        string memory p = _case(i);
        c.name = vm.parseJsonString(json, string.concat(p, ".name"));
        c.amount = vm.parseJsonUint(json, string.concat(p, ".amount"));
        c.pool = pool(json, string.concat(p, ".pool"));
        c.priya = venue(json, string.concat(p, ".priya"));
        string memory pv = string.concat(p, ".poolVenue");
        c.poolVenue.x = vm.parseJsonUint(json, string.concat(pv, ".x"));
        c.poolVenue.y = vm.parseJsonUint(json, string.concat(pv, ".y"));
        c.poolVenue.feeE9 = uint32(vm.parseJsonUint(json, string.concat(pv, ".feeE9")));
        c.poolCapIn = vm.parseJsonUint(json, string.concat(pv, ".capIn"));
        c.poolVenue.cap = c.poolCapIn;
        c.poolOnlyOut = vm.parseJsonUint(json, string.concat(p, ".poolOnlyOut"));
        string memory cf = string.concat(p, ".closedForm");
        c.allocPool = vm.parseJsonUint(json, string.concat(cf, ".allocPool"));
        c.allocPriya = vm.parseJsonUint(json, string.concat(cf, ".allocPriya"));
        c.poolLeg = vm.parseJsonUint(json, string.concat(cf, ".poolLeg"));
        c.priyaLeg = vm.parseJsonUint(json, string.concat(cf, ".priyaLeg"));
        c.totalInt = vm.parseJsonUint(json, string.concat(cf, ".totalInt"));
        if (vm.keyExistsJson(json, string.concat(p, ".v1Hinted"))) {
            string memory h = string.concat(p, ".v1Hinted");
            c.hasHint = true;
            c.hint = vm.parseJsonUint(json, string.concat(h, ".hint"));
            c.hintAquaLeg = vm.parseJsonUint(json, string.concat(h, ".aquaLeg"));
            c.hintPoolLeg = vm.parseJsonUint(json, string.concat(h, ".poolLeg"));
            c.hintTotal = vm.parseJsonUint(json, string.concat(h, ".total"));
        }
    }

    // ------------------------------------------------------------------ helpers

    function _case(uint256 i) private pure returns (string memory) {
        return string.concat(".cases[", vm.toString(i), "]");
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev Length of a JSON array of objects. Probes `[0]`, `[1]`, ... with `keyExistsJson`; the arrays here are
    ///      short (at most MAX_PROBE entries), so this is bounded.
    uint256 internal constant MAX_PROBE = 64;

    function _arrayLength(string memory json, string memory path) private view returns (uint256 n) {
        while (n < MAX_PROBE && vm.keyExistsJson(json, string.concat(path, "[", vm.toString(n), "]"))) n++;
    }
}
