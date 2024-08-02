// This is a general allocator that targets a fixed buffer.
// It can be used as a backing allocator for anything that expects to be able
// to randomly return blocks (Zig's GPA for example) or used entirely on its own.
//
// The basic functionality of this allocator is fairly simple.
// It contains tagged blocks, and is backed by two double-linked lists.
//
// The first list, the block list, just contains every block, in order. This is
// used so when a block is freed, we can merge it with adjacent blocks without
// needing to search the entire block list.
//
// The second list, the free list, is an unordered list of free blocks.
// When you allocate, this list is searched for a block that's large enough. If
// the block is too large, the allocator will split it, placing the newly created
// block into the free list and returning the re-sized block to you after removing
// it from the free list. When you free, the block you freed is added to the free
// list, then merged using the block list.
//
// The config for this allocator has a single optional input, minimum_block_size,
// which determines the smallest a block can be. Trying to allocate below that size
// (not including overhead) will simply return a block of that size instead.
// It defaults to 256.
//
// Overall, the allocator has a memory overhead per allocation of (@sizeOf(usize) * 5) + 1 bytes.
// Allocations are O(n) at worst, where n is the number of free blocks.
// Free is O(1).
// Resize is O(1).
//
// This allocator is generally meant to work on larger blocks of data. Doing many
// small allocations and frees can slow down the allocator if the blocks can't be
// merged, and the overhead per block starts being significant.
// If you want a bunch of small allocations, use zig's MemoryPool instead.
// You can even back a MemoryPool with one of these to really spice things up!

const std = @import("std");

const Config = struct {
    minimum_block_size: u32 = 256,
};

pub fn FixedBuffeHeapAllocator(comptime config: Config) type {
    return struct {
        const This = @This();

        const VTable = std.mem.Allocator.VTable{
            .alloc = &alloc,
            .resize = &resize,
            .free = &free,
        };

        // -- Fields -- //

        ///Slice containing the entire allocator's space.
        whole_slice: []u8 = undefined,

        //The first block, located at the start of the whole slice.
        first_block: *MemoryBlock = undefined,
        first_free: ?*MemoryBlock = undefined,

        root_call: bool = true,

        // -- Init -- //

        pub fn init(slice: []u8) !This {
            if (MemoryBlock.getEffectiveLength(slice.len) == 0)
                return error.SliceTooSmall;

            var ret = This{ .whole_slice = slice };

            const block = MemoryBlock.init(slice);
            ret.first_block = block;
            ret.first_free = block;

            return ret;
        }

        pub fn deinit(self: *This) void {
            _ = self;
        }

        // -- Methods -- //

        pub fn allocator(self: *This) std.mem.Allocator {
            return std.mem.Allocator{
                .ptr = self,
                .vtable = &VTable,
            };
        }

        /// VTable alloc function.
        fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
            const self: *This = @ptrCast(@alignCast(ctx));
            _ = ptr_align;
            _ = ret_addr;

            var currBlock: ?*MemoryBlock = self.first_free;
            //Loop through all free blocks.
            while (currBlock) |block| {
                //Set to iterate on next block.
                currBlock = block.next_free;

                //if block is too small, skip.
                if (block.effective_length < len)
                    continue;

                //Split block if required, then claim it.
                self.splitBlock(block, len);
                self.claimBlock(block);

                return block.getSlice().ptr;
            }

            return null;
        }

        /// VTable resize function
        fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
            const self: *This = @ptrCast(@alignCast(ctx));
            _ = self;
            _ = buf_align;
            _ = ret_addr;

            const block = MemoryBlock.getBlock(buf);

            //If new length is greater than or equal to old length, resize is OK.
            return block.effective_length >= new_len;
        }

        /// Free function
        fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
            const self: *This = @ptrCast(@alignCast(ctx));
            _ = buf_align;
            _ = ret_addr;

            const block = MemoryBlock.getBlock(buf);
            self.freeBlock(block);
        }

        // Block operations //

        /// Splits a free block into two halves
        pub fn splitBlock(self: *This, block: *MemoryBlock, len: usize) void {
            //Function is a bit of a nightmare but all of this math is basically just aligning where the new block will end up (if it exists)

            //Get current state of the block
            const current_start = @intFromPtr(self);
            //const current_end = current_start + @sizeOf(MemoryBlock) + block.effective_length;
            //const current_length = current_end - current_start;

            //Calculate aligned end point & length.
            const new_end = current_start + @sizeOf(MemoryBlock) + len;
            const new_end_aligned = std.mem.alignForward(usize, new_end, @alignOf(MemoryBlock));
            const new_length_aligned = MemoryBlock.getEffectiveLength(new_end_aligned - current_start);

            //Leftover is whatever we've got left after aligning it.
            const leftover = block.effective_length - new_length_aligned;

            //If new block's effective size is smaller than minimum bytes, don't bother splitting.
            if (MemoryBlock.getEffectiveLength(leftover) < config.minimum_block_size)
                return;

            //New block's slice exists at the new end to where the old end was.
            const new_slice = block.getSlice()[new_length_aligned..block.effective_length];
            const new_block = MemoryBlock.init(new_slice);

            block.effective_length = new_length_aligned;

            //Link into normal list
            {
                //Setup block itself.
                new_block.prev = block;
                new_block.next = block.next;

                //Setup neighbors.
                if (new_block.next) |next|
                    next.prev = new_block;
                if (new_block.prev) |prev|
                    prev.next = new_block;
            }

            //Link into free list.
            {
                new_block.next_free = self.first_free;
                self.first_free = new_block;

                if (new_block.next_free) |next|
                    next.prev_free = new_block;
            }
        }

        /// Claims a block, removing it from the free list.
        fn claimBlock(self: *This, block: *MemoryBlock) void {
            self.removeFromFree(block);
            block.is_free = false;
        }

        /// Frees a block, adding it to the free list and then merging it with nearby blocks if required.
        fn freeBlock(self: *This, block: *MemoryBlock) void {
            block.is_free = true;

            //If it's the first free block, just set it.
            if (self.first_free == null) {
                self.first_free = block;
                return;
            }

            //Put into list.
            self.first_free.?.prev_free = block;
            block.next_free = self.first_free;
            self.first_free = block;

            //Merge forward
            mergeForward(self, block);

            //Merge backward
            if (block.prev) |prev| {
                if (prev.is_free)
                    mergeForward(self, prev);
            }
        }

        fn mergeForward(self: *This, block: *MemoryBlock) void {
            if (block.next) |next| {
                if (next.is_free) {
                    //Steal length from block.
                    block.effective_length += @sizeOf(MemoryBlock) + next.effective_length;

                    //Delete the entire block.
                    self.deleteBlock(next);
                }
            }
        }

        fn deleteBlock(self: *This, block: *MemoryBlock) void {
            removeFromFree(self, block);

            //Remove from normal linked list.
            if (block.next) |next|
                next.prev = block.prev;
            if (block.prev) |prev|
                prev.next = block.next;
        }

        fn removeFromFree(self: *This, block: *MemoryBlock) void {
            //If this is the only block in the free list, set the first block to whatever is after this (there can't be anything before)
            if (self.first_free == block)
                self.first_free = block.next_free;

            //Otherwise, Remove from free list,
            if (block.next_free) |next|
                next.prev_free = block.prev_free;
            if (block.prev_free) |prev|
                prev.next_free = block.next_free;

            block.next_free = null;
            block.prev_free = null;
        }

        // -- Nested -- //

        const MemoryBlock = struct {
            is_free: bool = false,
            effective_length: usize,

            //Block linked list pointers.
            next: ?*MemoryBlock = null,
            prev: ?*MemoryBlock = null,

            //Free linked list pointers.
            next_free: ?*MemoryBlock = null,
            prev_free: ?*MemoryBlock = null,

            /// Initializes a memory block using a slice.
            /// This will 'allocate' a memory block to the beginning of the slice, then return a pointer to that new MemoryBlock.
            /// You can deallocate the slice if need be by pointer casting it back to a slice, as the memory block is located at the address the slice started at.
            pub fn init(slice: []u8) *MemoryBlock {
                //TODO - Align input

                //Create block at beginning of slice.
                const block: *MemoryBlock = @alignCast(@ptrCast(slice.ptr));
                block.is_free = true;
                block.effective_length = getEffectiveLength(@intCast(slice.len));
                block.next = null;
                block.prev = null;
                block.next_free = null;
                block.prev_free = null;

                return block;
            }

            //Retrieves a block from an existing slice.
            pub fn getBlock(blockSlice: []u8) *MemoryBlock {
                return @alignCast(@ptrCast(blockSlice.ptr - @sizeOf(MemoryBlock)));
            }

            ///Gets the slice for this memory block.
            pub fn getSlice(self: *MemoryBlock) []u8 {
                const arr: [*]u8 = @ptrFromInt(@intFromPtr(self) + @sizeOf(MemoryBlock));
                return arr[0..self.effective_length];
            }

            ///Gets the effective length, which is the space of a slice minus what's going to be taken by a block.
            pub fn getEffectiveLength(len: usize) usize {
                if (len < @sizeOf(MemoryBlock))
                    return 0;
                return len - @sizeOf(MemoryBlock);
            }
        };
    };
}
