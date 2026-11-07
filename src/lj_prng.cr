# LuaJIT TW223 PRNG (Externals/LuaJIT/src/lj_prng.c) — bit-exact port.
#
# The xray engine build uses the FIXED seed (LUAJIT_SECURITY_PRNG=0
# semantics: lj_prng_seed_fixed = precomputed random_seed(rs, 0.0)), which
# makes math.random() sequences reproducible run-to-run. The VibeRay
# lua_run corpus depends on that reproducibility: scripts branch on
# math.random() values, and the engine oracle picks deterministic branches.

module Lua
  class LuaJitPrng
    @u : StaticArray(UInt64, 4)

    # lj_prng_seed_fixed (precomputed random_seed(rs, 0.0))
    def initialize
      @u = uninitialized StaticArray(UInt64, 4)
      @u[0] = 0xa0d277570a345b8c_u64
      @u[1] = 0x764a296c5d4aa64f_u64
      @u[2] = 0x51220704070adeaa_u64
      @u[3] = 0x2a2717b5a7b7b927_u64
    end

    def seed_fixed : Nil
      @u[0] = 0xa0d277570a345b8c_u64
      @u[1] = 0x764a296c5d4aa64f_u64
      @u[2] = 0x51220704070adeaa_u64
      @u[3] = 0x2a2717b5a7b7b927_u64
    end

    # TW223_GEN
    macro gen(i, k, q, s)
      z = @u[{{ i }}]
      z = (((z << {{ q }}) ^ z) >> ({{ k }} - {{ s }})) ^
        ((z & (UInt64::MAX << (64 - {{ k }}))) << {{ s }})
      r ^= z
      @u[{{ i }}] = z
    end

    # lj_prng_u64
    def next_u64 : UInt64
      z = 0_u64
      r = 0_u64
      gen(0, 63, 31, 18)
      gen(1, 58, 19, 28)
      gen(2, 55, 24, 7)
      gen(3, 47, 21, 8)
      r
    end

    # lj_prng_u64d: bit pattern of a double in [1.0, 2.0)
    def next_u64d : UInt64
      (next_u64 & 0x000fffffffffffff_u64) | 0x3ff0000000000000_u64
    end

    # math.random() raw value: double in [0, 1)
    def next_double : Float64
      next_u64d.unsafe_as(Float64) - 1.0
    end

    # lib_math.c random_seed
    def seed(d : Float64) : Nil
      r = 0x11090601_u32 # 64-k[i] as four 8 bit constants
      4.times do |i|
        m = 1_u32 << (r & 255)
        r >>= 8
        d = d * 3.14159265358979323846 + 2.7182818284590452354
        u = d.unsafe_as(UInt64)
        u += m.to_u64! if u < m # ensure k[i] MSB of u[i] are non-zero
        @u[i] = u
      end
      10.times { next_u64 }
    end
  end
end
