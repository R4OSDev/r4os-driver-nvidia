//! Worker-owned evidence for one Window flip. GPU notifier timestamps and
//! CPU IRQ observation times remain distinct clock domains. A later head
//! event helps bound missing IRQs; it never replaces Window BEGUN/FINISHED.
const head_events = @import("gsp_head_events.zig");

pub const Receipt = struct {
    epoch: u64,
    sequence: u64,
    head: u32,
    window: u32,
    previous_dma: u32,
    image_dma: u32,
    render_point: u32,
    source_timeline: u64 = 0,
    source_point: u64 = 0,
    window_point: u64 = 0,
    submitted_ns: u64 = 0,
    begun_gpu_timestamp: u64 = 0,
    begun_observed_ns: u64 = 0,
    head_observation: head_events.Sample = .{},
    previous_released_ns: u64 = 0, // Released from scanout; the allocation remains owned.
};
