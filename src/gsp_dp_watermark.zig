// NVIDIA 570.144 dp_watermark.cpp, isModePossibleSSTWithFEC (MIT).
// SPDX-FileCopyrightText: Copyright (c) 1993-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//
//! FEC-aware SST watermarks and blanking. R4OS passes the actual admitted
//! PPS slice geometry; upstream's fixed four/eight-slice assumption is not
//! substituted for the encoder configuration. This computes no hardware ACK.
const links = @import("r4gfx_edid").links;
pub const Error = error{ Parameter, Bandwidth };
pub const Stream = struct { watermark: u32, hblank: u32, vblank: u32, audio_48k: bool };
pub const Slice = struct { count: u8, width: u16, chunk_bytes: u16 };
pub const Input = struct {
    clock: links.Clock,
    width: u32,
    total: u32,
    bpp_x16: u16,
    rate: u8,
    lanes: u8,
    enhanced: bool,
    increased: bool,
    compression: ?Slice = null,
};
pub fn payload(rate: u8, lanes: u8) Error!u64 {
    const raw = links.dp8b10bPayload(rate, lanes) catch return error.Parameter;
    // NVIDIA LinkConfiguration::linkOverhead: 2.4% FEC + 0.6% downspread.
    return raw * 97 / 100;
}
fn ceil(n: u64, d: u64) u64 {
    return (n + d - 1) / d;
}
fn parity(lanes: u64, clocks: u64) u64 {
    const block: u64 = if (lanes == 1) 512 else 256;
    const bytes: u64 = if (lanes == 1) 12 else 6;
    return @min(clocks % block, bytes) + clocks / block * bytes + bytes + 1;
}
pub fn withFec(input: Input) Error!Stream {
    const capacity = try payload(input.rate, input.lanes);
    if (!input.clock.atMost(4_000_000_000) or input.width <= 60 or input.width > 65535 or input.total <= input.width or
        input.total > 65535 or input.bpp_x16 == 0 or input.bpp_x16 > 768) return error.Parameter;
    const demand: links.Demand = .{ .clock = input.clock, .bpp_x16 = input.bpp_x16 };
    if (!demand.fits(capacity)) return error.Bandwidth;
    if (input.compression != null and @as(u128, input.clock.numerator) * input.bpp_x16 * 64 <
        @as(u128, capacity) * 16 * input.clock.denominator) return error.Bandwidth; // No zero-active-symbol TU.
    const pclk = input.clock.ceilHz() catch return error.Parameter;
    const peak: u64 = @as(u64, input.rate) * 27_000_000;
    const rate = peak * 97 / 100;
    const lanes: u64 = input.lanes;
    const width: u64 = input.width;
    const bpp: u64 = input.bpp_x16;
    const precision: u64 = 100_000;
    const ratio = (pclk * bpp * precision / 16) / (8 * rate * lanes);
    if (ratio >= precision) return error.Bandwidth;
    const fraction = ratio * 64 * (precision - ratio) / precision;
    const adjust: u64 = if (input.increased) 8 else 2;
    var watermark = adjust + (3 * (bpp * precision / (8 * lanes * 16)) + fraction) / precision + 8 / lanes + 3 +
        ratio * @as(u64, if (lanes == 1) 15 else 10) / precision;
    if (watermark > width * bpp / (8 * lanes * 16)) return error.Bandwidth;
    // FEC uses the increased formula; the old non-FEC maximum39 does not
    // apply (the independent one-lane original vector yields45).
    watermark = @max(watermark, @as(u64, if (input.increased) 22 else 20));
    var blank_bits: u64 = 96 + 16 * lanes;
    if (input.compression) |slices| {
        if (slices.count == 0 or slices.count > 24 or slices.width == 0 or slices.chunk_bytes == 0 or
            ceil(width, slices.width) != slices.count or ceil(@as(u64, slices.width) * bpp, 128) != slices.chunk_bytes) return error.Parameter;
        const chunk: u64 = slices.chunk_bytes;
        const count: u64 = slices.count;
        const slice_width: u64 = slices.width;
        if ((chunk + 1) * count * pclk < rate * lanes * width) {
            blank_bits += 8 * lanes + chunk * 8 - slice_width * bpp / 16 + count * 8 * (ceil(chunk, lanes) * lanes - chunk);
        } else blank_bits += count * 8 * lanes + count * (ceil(chunk, lanes) * lanes * 8 - slice_width * bpp / 16);
    } else {
        if (bpp % 16 != 0) return error.Parameter;
        blank_bits += ceil(ceil(width, lanes) * (bpp / 16), 8) * 8 * lanes - width * (bpp / 16);
    }
    var blank_symbols = ceil(blank_bits, 8 * lanes) + @as(u64, if (input.enhanced) 3 else 0);
    const fec_margin = parity(lanes, blank_symbols);
    blank_symbols += fec_margin;
    const min_blank = ceil(blank_symbols * pclk, peak) + 3;
    const blank: u64 = input.total - input.width;
    if (min_blank > blank) return error.Bandwidth;
    const total_symbols = ceil(blank * peak, pclk);
    const available = (blank - min_blank) * peak / pclk + fec_margin;
    const hblank = available -| (parity(lanes, total_symbols) + 7);
    const packets = ((hblank * lanes) -| (4 * lanes + 8)) / 20;
    const audio = packets >= ceil(48_000 * @as(u64, input.total), pclk * 2);
    const squeezed = 96 -| hblank;
    const msa = 36 / lanes + 3;
    const vpre = ((width - 3) * peak / pclk) -| (squeezed + msa);
    const vblank = vpre -| (parity(lanes, vpre) + 3);
    if (input.compression != null and vblank < @as(u64, if (lanes == 1) 183 else if (lanes == 2) 89 else 47)) return error.Bandwidth;
    return .{ .watermark = @intCast(watermark), .hblank = @intCast(hblank), .vblank = @intCast(vblank), .audio_48k = audio };
}
