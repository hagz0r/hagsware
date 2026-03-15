const mem = @import("../utils/memory.zig");

const entity_list_chunk_start: usize = 0x0;
const entity_list_chunk_stride: usize = 0x8;
const entity_identity_stride: usize = 0x70;
const entity_identity_entity_offset: usize = 0x0;
const entity_identity_handle_offset: usize = 0x10;
const entity_page_mask: u32 = 0x1FF;
const entity_index_mask: u32 = 0x7FFF;

pub fn getEntityByHandle(entity_list: usize, handle: u32) ?usize {
    const index = handle & entity_index_mask;
    if (index == 0) return null;

    const identity = getEntityIdentity(entity_list, index) orelse return null;
    const identity_handle = mem.read(u32, identity + entity_identity_handle_offset) orelse return null;
    if (identity_handle != handle) return null;

    const entity = mem.read(usize, identity + entity_identity_entity_offset) orelse return null;
    if (entity == 0) return null;
    return entity;
}

pub fn getEntityByIndex(entity_list: usize, index: u32) ?usize {
    const identity = getEntityIdentity(entity_list, index) orelse return null;
    const entity = mem.read(usize, identity + entity_identity_entity_offset) orelse return null;
    if (entity == 0) return null;
    return entity;
}

fn getEntityIdentity(entity_list: usize, index: u32) ?usize {
    const chunk_index = index >> 9;
    const chunk_addr = entity_list + entity_list_chunk_start + entity_list_chunk_stride * chunk_index;
    const chunk = mem.read(usize, chunk_addr) orelse return null;
    if (chunk == 0) return null;

    const entity_index_in_page = index & entity_page_mask;
    return chunk + entity_identity_stride * entity_index_in_page;
}
