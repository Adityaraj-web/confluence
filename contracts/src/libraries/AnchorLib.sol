// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title AnchorLib
/// @notice The anchor's maths: a block-start snapshot and a time-weighted EMA in tick space (ARCHITECTURE-v2
/// section 4). Pure. Fixed-point format, rounding and the exp2 method are in D-31.
/// @dev The EMA is stored as tick x 2^16 (`emaTickX`). One update is
/// `ema' = snap + (ema - snap) * 2^(-dt/H)`, computed on the deviation `ema - snap` with a Q128 factor and signed
/// division, which truncates toward zero. So a deviation shrinks toward the snapshot by the same rule from above and
/// from below, and the result stays between the old EMA and the snapshot.
library AnchorLib {
    /// @notice One pool's anchor, packed into one slot (184 bits; the top 72 are unused).
    struct Anchor {
        uint40 lastTimestamp;
        uint64 lastBlock;
        int24 snapTick;
        int56 emaTickX;
    }

    /// @notice A gap of this many half-lives or more gives a factor of 0: the EMA equals the snapshot.
    uint256 internal constant CUTOFF_HALF_LIVES = 16;
    /// @dev Bits of the fractional half-life that the factor resolves (32 steps below).
    uint256 internal constant FRAC_BITS = 32;
    uint256 internal constant ONE_X128 = 1 << 128;
    int256 internal constant TICK_SCALE = 1 << 16;

    /// @notice 2^(-dt/H) as a Q128 number, in [0, 2^128]. 0 from `CUTOFF_HALF_LIVES * halfLife` on.
    /// @dev `halfLife` must be in [1, 2^32]. dt = q*H + r: the factor is 2^(-r/H) >> q. The fraction x = r/H is
    /// taken to 32 bits, and 2^(-x) is the product of the constants C_i = floor(2^128 * 2^(-2^-i)) for each set bit
    /// i of x (generated with Python's decimal at 100 digits, see D-31). Each product rounds down by one Q128 ulp,
    /// and cutting x to 32 bits costs at most 2^-32 * ln 2 relative: under 0.0003 of a tick across the whole range.
    /// Each product is below 2^256 because both factors are at most 2^128.
    function decayX128(uint256 dt, uint256 halfLife) internal pure returns (uint256 f) {
        if (dt >= CUTOFF_HALF_LIVES * halfLife) return 0;
        uint256 q = dt / halfLife;
        uint256 x = ((dt % halfLife) << FRAC_BITS) / halfLife;
        f = ONE_X128;
        if (x & 2147483648 != 0) f = (f * 0xb504f333f9de6484597d89b3754abe9f) >> 128; // i=1
        if (x & 1073741824 != 0) f = (f * 0xd744fccad69d6af439a68bb9902d3fde) >> 128; // i=2
        if (x & 536870912 != 0) f = (f * 0xeac0c6e7dd24392ed02d75b3706e54fa) >> 128; // i=3
        if (x & 268435456 != 0) f = (f * 0xf5257d152486cc2c7b9d0c7aed980fc3) >> 128; // i=4
        if (x & 134217728 != 0) f = (f * 0xfa83b2db722a033a7c25bb14315d7fcc) >> 128; // i=5
        if (x & 67108864 != 0) f = (f * 0xfd3e0c0cf486c174853f3a5931e0ee03) >> 128; // i=6
        if (x & 33554432 != 0) f = (f * 0xfe9e115c7b8f884badd25995e79d2f09) >> 128; // i=7
        if (x & 16777216 != 0) f = (f * 0xff4ecb59511ec8a5301ba217ef18dd7c) >> 128; // i=8
        if (x & 8388608 != 0) f = (f * 0xffa756521c8daed19f3a1b48fb94c589) >> 128; // i=9
        if (x & 4194304 != 0) f = (f * 0xffd3a751c0f7e10bd3b9f8ae012fbe06) >> 128; // i=10
        if (x & 2097152 != 0) f = (f * 0xffe9d2b2f7db2755ddf1d28a378a438c) >> 128; // i=11
        if (x & 1048576 != 0) f = (f * 0xfff4e91bff1b8c3d88338e0ebf284a4d) >> 128; // i=12
        if (x & 524288 != 0) f = (f * 0xfffa747ea0040664238f92f792405805) >> 128; // i=13
        if (x & 262144 != 0) f = (f * 0xfffd3a3b7814eb53cd7629d70fea116a) >> 128; // i=14
        if (x & 131072 != 0) f = (f * 0xfffe9d1cc60ddab126de1aec4a87e7b8) >> 128; // i=15
        if (x & 65536 != 0) f = (f * 0xffff4e8e25879bfa09ea263360240c1a) >> 128; // i=16
        if (x & 32768 != 0) f = (f * 0xffffa7470363f4515426d76c762b6b61) >> 128; // i=17
        if (x & 16384 != 0) f = (f * 0xffffd3a37dda03133bde87a8379c8932) >> 128; // i=18
        if (x & 8192 != 0) f = (f * 0xffffe9d1bdf703aef21ea4dcfb0682d8) >> 128; // i=19
        if (x & 4096 != 0) f = (f * 0xfffff4e8debe025e24128a3d460731f1) >> 128; // i=20
        if (x & 2048 != 0) f = (f * 0xfffffa746f4fa1506788fbc89750bf71) >> 128; // i=21
        if (x & 1024 != 0) f = (f * 0xfffffd3a37a3f8b07e7c4871dc00d76e) >> 128; // i=22
        if (x & 512 != 0) f = (f * 0xfffffe9d1bd1065a50971275792f1c83) >> 128; // i=23
        if (x & 256 != 0) f = (f * 0xffffff4e8de845adac77243cd0914b37) >> 128; // i=24
        if (x & 128 != 0) f = (f * 0xffffffa746f41376f74124cd483186d4) >> 128; // i=25
        if (x & 64 != 0) f = (f * 0xffffffd3a37a05e383e14c90273c94f5) >> 128; // i=26
        if (x & 32 != 0) f = (f * 0xffffffe9d1bd01fbc400bf822dc936b5) >> 128; // i=27
        if (x & 16 != 0) f = (f * 0xfffffff4e8de80c062846365949b61af) >> 128; // i=28
        if (x & 8 != 0) f = (f * 0xfffffffa746f4050d1633246a8a0e09a) >> 128; // i=29
        if (x & 4 != 0) f = (f * 0xfffffffd3a37a02490b9d93da3c1ebcf) >> 128; // i=30
        if (x & 2 != 0) f = (f * 0xfffffffe9d1bd011525efca410b8eab7) >> 128; // i=31
        if (x & 1 != 0) f = (f * 0xffffffff4e8de8086bb002532d71e54d) >> 128; // i=32
        f >>= q;
    }

    /// @notice The EMA after `dt` seconds at snapshot `snap`, in tick x 2^16.
    /// @dev The deviation is at most 2 * 887272 * 2^16 < 2^38 and the factor at most 2^128, so the product is below
    /// 2^166. The result lies between `emaX` and `snap * 2^16`, so it fits `int56`.
    function nextEmaX(int256 emaX, int24 snap, uint256 dt, uint256 halfLife) internal pure returns (int56) {
        int256 snapX = int256(snap) * TICK_SCALE;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 f = int256(decayX128(dt, halfLife)); // at most 2^128
        // forge-lint: disable-next-line(unsafe-typecast)
        return int56(snapX + ((emaX - snapX) * f) / int256(ONE_X128));
    }

    /// @notice The EMA as a whole tick: the nearest, ties up, with every tick's bucket 2^16 wide on both sides of 0.
    /// @dev `>>` on a signed value rounds toward negative infinity, so adding half a tick first rounds to nearest.
    /// V2-04's drift check must not use this: it compares `snap * 2^16` with `emaTickX` (D-31).
    function emaTick(int56 emaX) internal pure returns (int24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24((int256(emaX) + TICK_SCALE / 2) >> 16);
    }

    /// @notice The anchor after the first swap of a block (or the lazy view of it): `snap` = `slotTick`, and the EMA
    /// moved toward it. The first ever touch (`lastBlock == 0`) sets the EMA to the snapshot.
    /// @dev `dt` is the difference of the timestamps modulo 2^40, so a wrapped `uint40` still gives the true gap
    /// for gaps under 2^40 s. Block numbers of 2^64 or more are not supported.
    function next(Anchor memory a, int24 slotTick, uint256 timestamp, uint256 blockNumber, uint256 halfLife)
        internal
        pure
        returns (Anchor memory n)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        n.lastTimestamp = uint40(timestamp);
        // forge-lint: disable-next-line(unsafe-typecast)
        n.lastBlock = uint64(blockNumber);
        n.snapTick = slotTick;
        if (a.lastBlock == 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            n.emaTickX = int56(int256(slotTick) * TICK_SCALE);
        } else {
            uint256 dt;
            unchecked {
                dt = uint40(n.lastTimestamp - a.lastTimestamp);
            }
            n.emaTickX = nextEmaX(a.emaTickX, slotTick, dt, halfLife);
        }
    }
}
