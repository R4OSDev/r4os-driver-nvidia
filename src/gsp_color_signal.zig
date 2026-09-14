//! The display transaction carries one explicit pixel/signal contract. The
//! canonical userland admission helper owns color semantics; this adapter
//! supplies implemented source stages and the actual link budget.
pub const color = @import("r4gfx_outputs").color;
pub const sdr: color.Signal = .{ .format = .xr24, .transfer = .srgb, .primaries = .bt709,
    .range = .full, .bpc = 8, .reference_white = 1_000_000, .peak = 1_000_000 };
/// Only color/link facts are retained, not the receiver's large mode array.
pub const Receiver = struct {
    valid: bool, digital: bool, colors: u32, hdmi: bool, hdmi_deep_color: u8,
    rgb_quantization_selectable: bool, max_tmds_hz: u64, scdc: bool,
    bits_per_color: u8, colorimetry: u16, hdr_present: bool, hdr_eotf: u8, hdr_static: u8,
    pub fn complete(self: Receiver) bool { return self.valid; }
    pub fn capture(report: anytype) Receiver {
        return .{ .valid = report.complete(), .digital = report.digital, .colors = report.colors,
            .hdmi = report.hdmi, .hdmi_deep_color = report.hdmi_deep_color,
            .rgb_quantization_selectable = report.rgb_quantization_selectable,
            .max_tmds_hz = report.max_tmds_hz, .scdc = report.scdc, .bits_per_color = report.bits_per_color,
            .colorimetry = report.colorimetry, .hdr_present = report.hdr_present,
            .hdr_eotf = report.hdr_eotf, .hdr_static = report.hdr_static };
    }
};
pub fn source(transport: color.Transport) color.Source {
    return if (transport == .dvi) .{ .formats = 1, .bpc = 1, .primaries = 1, .ranges = 1, .eotf = 1 }
        else .{ .formats = 3, .bpc = 3, .primaries = 3, .ranges = 3, .eotf = 13,
            .static_metadata = true, .dp_vsc = transport == .displayport };
}
pub fn clockHz(saved: anytype) u64 {
    const nominal: u64 = saved.signal.clock & 0x7fffffff;
    return if (saved.signal.clock >> 31 != 0) (nominal * 1000 + 1000) / 1001 else nominal;
}
pub fn validate(saved: anytype) !void {
    if (saved.color) |signal| {
        if (saved.signal.bpc != signal.bpc or saved.signal.dp_vsc != (saved.displayPort() and needsVsc(signal))) return error.Descriptor;
    } else if (saved.signal.bpc != 8 or saved.signal.dp_vsc) return error.Descriptor;
}
pub fn needsVsc(signal: color.Signal) bool { return signal.transfer != .srgb or signal.primaries != .bt709 or signal.range != .full; }
pub fn admit(saved: anytype, receiver: anytype, link: color.Link) !?color.Plan {
    try validate(saved);
    const signal = saved.color orelse return null;
    const transport: color.Transport = switch (link) { .hdmi => .hdmi, .dvi => .dvi, .displayport => .displayport };
    return try color.admit(receiver, signal, source(transport), saved.color_pipeline, link, clockHz(saved), saved.cta_vic);
}
