// Original R4OS bounded namespace/retention policy: Apache-2.0. Client
// namespace and generated-range facts: pinned Nouveau/NVIDIA (MIT).
// Nvidia570.144/src/nvidia/src/kernel/rmapi/client.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 1993-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//  * SPDX-License-Identifier: MIT
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
// Nvidia570.144/src/nvidia/inc/libraries/resserv/rs_client.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2015-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//  * SPDX-License-Identifier: MIT
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
// Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/handles.h
// /* SPDX-License-Identifier: MIT
//  *
//  * Copyright (c) 2025, NVIDIA CORPORATION. All rights reserved.
//  */
// Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/client.c
// /* SPDX-License-Identifier: MIT
//  *
//  * Copyright (c) 2025, NVIDIA CORPORATION. All rights reserved.
//  */
// Nouveau/LICENSES/preferred/MIT
// Valid-License-Identifier: MIT
// SPDX-URL: https://spdx.org/licenses/MIT.html
// Usage-Guide:
//   To use the MIT License put the following SPDX tag/value pair into a
//   comment according to the placement guidelines in the licensing rules
//   documentation:
//     SPDX-License-Identifier: MIT
// License-Text:
//
// MIT License
//
// Copyright (c) <year> <copyright holders>
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
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//! Session-owned RM namespace. One ledger is retained across every runtime
//! handoff in that firmware run; all R4OS RM clients allocate through it.
//! Mutation belongs to the serialized runtime worker, never an IRQ callback.
//! Retiring bookkeeping never reissues a wire name or proves GPU quiescence.
const std = @import("std");
pub const Error = error{ Stale, Bounds, Exhausted, Retained };
pub const max_clients = 64;
// Client naming follows Nouveau's RM client namespace. Object names are an
// R4OS allocation policy, below both RM(0xcaf00000..0xcaf7ffff) and firmware
// (0xc9f00000..0xc9f7ffff) generated ranges in the pinned570.144 sources.
pub const client_base: u32 = 0xc1d00000;
pub const client_mask: u32 = 0x0000ffff;
pub const object_first: u32 = 0x10000000;
pub const object_end: u32 = 0x80000000;
pub const Lease = struct {
    epoch: u64,
    slot: u8,
    client: u32,
    first_object: u32,
    object_count: u16,

    pub fn object(self: Lease, index: u16) Error!u32 {
        if (index >= self.object_count) return error.Bounds;
        if (self.first_object < object_first or self.first_object >= object_end or index >= object_end - self.first_object) return error.Bounds;
        return self.first_object + index;
    }
};
const Entry = struct { lease: ?Lease = null, retained: bool = false };
pub const max_child_ranges = 256;
pub const Children = struct {
    parent: Lease,
    slot: u16,
    first_object: u32,
    object_count: u16,

    pub fn object(self: Children, index: u16) Error!u32 {
        if (index >= self.object_count or self.first_object < object_first or
            self.first_object >= object_end or index >= object_end - self.first_object) return error.Bounds;
        return self.first_object + index;
    }
};
const ChildEntry = struct { lease: ?Children = null, retained: bool = false };
pub const Ledger = struct {
    epoch: u64,
    next_client: u32 = 0,
    next_object: u32 = object_first,
    entries: [max_clients]Entry = @splat(.{}),
    children: [max_child_ranges]ChildEntry = @splat(.{}),

    pub fn init(epoch: u64) error{Stale}!Ledger {
        if (epoch == 0) return error.Stale;
        return .{ .epoch = epoch };
    }
    /// Reserve the root and all initial child names atomically before RM I/O.
    /// Names consumed by a later rejected allocation remain burned this run.
    pub fn reserve(self: *Ledger, count: u16) Error!Lease {
        if (self.epoch == 0) return error.Stale;
        if (count == 0) return error.Bounds;
        if (self.next_client > client_mask or self.next_object < object_first or self.next_object >= object_end or count > object_end - self.next_object) return error.Exhausted;
        for (&self.entries, 0..) |*entry, slot| {
            if (entry.lease != null) continue;
            const lease = Lease{ .epoch = self.epoch, .slot = @intCast(slot), .client = client_base | self.next_client, .first_object = self.next_object, .object_count = count };
            entry.* = .{ .lease = lease };
            self.next_client += 1;
            self.next_object += count;
            return lease;
        }
        return error.Exhausted;
    }
    fn lookup(self: *Ledger, lease: Lease) Error!*Entry {
        if (lease.epoch != self.epoch or lease.slot >= max_clients) return error.Stale;
        const selected = &self.entries[lease.slot];
        if (!std.meta.eql(selected.lease orelse return error.Stale, lease)) return error.Stale;
        return selected;
    }
    pub fn validate(self: *Ledger, lease: Lease) Error!void {
        if ((try self.lookup(lease)).retained) return error.Retained;
    }
    /// Called only by an owner which has not submitted anything or has ACKed
    /// every RM child/root free. The counters are deliberately not rewound.
    pub fn retire(self: *Ledger, lease: Lease) Error!void {
        try self.requireNoChildren(lease);
        (try self.lookup(lease)).* = .{};
    }
    /// Required before transmitting parent destruction, not just retiring its
    /// bookkeeping after RM has already recursively freed live children.
    pub fn requireNoChildren(self: *Ledger, lease: Lease) Error!void {
        try self.validate(lease);
        for (&self.children) |child| if (child.lease) |held| {
            if (std.meta.eql(held.parent, lease)) return error.Retained;
        };
    }
    /// An uncertain graph stays in the ledger until the whole device run is
    /// discarded after independent quiescence. There is no unretain method.
    pub fn retain(self: *Ledger, lease: Lease) Error!void {
        (try self.lookup(lease)).retained = true;
    }
    /// Dynamic objects belong to the existing client. Its immutable parent
    /// lease never changes size, and child retirement never recycles names.
    pub fn reserveChildren(self: *Ledger, parent: Lease, count: u16) Error!Children {
        try self.validate(parent);
        if (count == 0) return error.Bounds;
        if (self.next_object < object_first or self.next_object >= object_end or count > object_end - self.next_object) return error.Exhausted;
        for (&self.children, 0..) |*entry, slot| {
            if (entry.lease != null) continue;
            const value: Children = .{ .parent = parent, .slot = @intCast(slot), .first_object = self.next_object, .object_count = count };
            entry.* = .{ .lease = value };
            self.next_object += count;
            return value;
        }
        return error.Exhausted;
    }
    fn lookupChildren(self: *Ledger, lease: Children) Error!*ChildEntry {
        _ = try self.lookup(lease.parent);
        if (lease.slot >= self.children.len) return error.Stale;
        const selected = &self.children[lease.slot];
        if (!std.meta.eql(selected.lease orelse return error.Stale, lease)) return error.Stale;
        return selected;
    }
    pub fn validateChildren(self: *Ledger, lease: Children) Error!void {
        try self.validate(lease.parent);
        if ((try self.lookupChildren(lease)).retained) return error.Retained;
    }
    pub fn retireChildren(self: *Ledger, lease: Children) Error!void {
        try self.validateChildren(lease);
        (try self.lookupChildren(lease)).* = .{};
    }
    pub fn retainChildren(self: *Ledger, lease: Children) Error!void {
        (try self.lookupChildren(lease)).retained = true;
        try self.retain(lease.parent);
    }
};
