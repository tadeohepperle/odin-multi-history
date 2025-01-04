package history

import "core:fmt"
import "core:mem"
import "core:slice"
print :: fmt.println
tprint :: fmt.tprint

// The MultiHistory supports up to 64 different types
MAX_TYPE_COUNT :: size_of(u64) * 8
MultiHistory :: struct {
	types:          [MAX_TYPE_COUNT]_Type,
	types_len:      int,
	snapshots:      []_Snapshot, // should have len == cap, a history of which tracks got affected by the change
	cap:            int,
	first_past_idx: int, // marks start of p,p,p,p,f,f where p are past snapshots and f future snapshots
	past_len:       int,
	future_len:     int,
}
_Type :: struct {
	ptr_id:   typeid, // = ^T
	id:       typeid, // = T
	size:     int,
	align:    int,
	bit_mask: u64, // = 2 << idx of this type in types array
	drop:     proc(el: rawptr),
	clone:    proc(src: rawptr, dst: rawptr),
}
// the ptr points to an allocation that contains the types specified in 
_Snapshot :: struct {
	bit_mask:   u64,
	total_size: int, // size of allocation at ptr
	alloc_ptr:  rawptr,
}
_Mapping :: struct {
	ty:       ^_Type,
	data_ptr: rawptr,
}
_make_mappings :: proc(
	types: []_Type,
	value_anys: []any,
) -> (
	mappings: []_Mapping,
	bit_mask: u64,
	total_size: int,
) {
	mappings = make([]_Mapping, len(value_anys))
	i := 0
	outer: for &ty in types {
		for val in value_anys {
			if ty.id == val.id {
				// found the right thing
				bit_mask |= ty.bit_mask
				total_size = mem.align_forward_int(total_size, ty.align)
				total_size += ty.size
				mappings[i] = _Mapping{&ty, val.data}
				i += 1
				continue outer
			}
		}
	}
	if i != len(mappings) {
		panic(
			tprint(
				"something went wrong in _make_mappings, a type from the any values is probably not registered",
			),
		)
	}
	return mappings, bit_mask, total_size
}
// values are direct values made into anys, such that any.data is assumed to be ^T
_snapshot_create :: proc(types: []_Type, value_anys: []any) -> _Snapshot {
	mappings, bit_mask, total_size := _make_mappings(types, value_anys)
	defer delete(mappings)
	alloc_ptr, err := mem.alloc(total_size)
	assert(err == .None)

	// copy data over into the allocation
	cur_ptr := alloc_ptr
	last_bit_mask: u64 = 0
	for m in mappings {
		assert(m.ty.bit_mask > last_bit_mask)
		last_bit_mask = m.ty.bit_mask // assures that the mappings are in ascending order
		cur_ptr = mem.align_forward(cur_ptr, uintptr(m.ty.align))
		// clone data into the allocation:
		if m.ty.clone == nil {
			mem.copy_non_overlapping(cur_ptr, m.data_ptr, m.ty.size)
		} else {
			m.ty.clone(m.data_ptr, cur_ptr)
		}
		// increment cur_ptr by size of this type to get the next slot
		cur_ptr = rawptr(uintptr(cur_ptr) + uintptr(m.ty.size))
	}
	return _Snapshot{bit_mask, total_size, alloc_ptr}
}
_snapshot_drop :: proc(this: ^_Snapshot, types: []_Type) {
	iter := _iter(this, types)
	for {
		dst_ptr, type := _next(&iter) or_break
		if type.drop != nil {
			type.drop(dst_ptr)
		}
	}
	// in the end dealloc the allocation:
	mem.free(this.alloc_ptr)
	this^ = _Snapshot{0, 0, nil} // zero out memory
}
_access_types :: proc(this: ^MultiHistory) -> []_Type {
	return this.types[:this.types_len]
}
multi_history_create :: proc(cap: int) -> MultiHistory {
	return MultiHistory{cap = cap, snapshots = make([]_Snapshot, cap)}
}
multi_history_info :: proc(this: MultiHistory) -> (past_len: int, future_len: int, cap: int) {
	return this.past_len, this.future_len, this.cap
}
multi_history_add_type :: proc {
	multi_history_add_copy_type,
	multi_history_add_managed_type,
}
_add_type :: proc(this: ^MultiHistory, type: _Type) {
	assert(this.types_len < MAX_TYPE_COUNT)
	this.types[this.types_len] = type
	this.types_len += 1
}
multi_history_add_copy_type :: proc(this: ^MultiHistory, $T: typeid) {
	type := _Type {
		id       = T,
		ptr_id   = typeid_of(^T),
		size     = size_of(T),
		align    = align_of(T),
		drop     = nil,
		clone    = nil,
		bit_mask = 2 << u64(this.types_len),
	}
	_add_type(this, type)
}
multi_history_add_managed_type :: proc(
	this: ^MultiHistory,
	$T: typeid,
	$CLONE_FN: proc(el: T) -> T,
	$DROP_FN: proc(el: ^T),
) {
	clone_fn := proc(src, dst: rawptr) {
		src_t := cast(^T)src
		dst_t := cast(^T)dst
		dst_t^ = CLONE_FN(src_t^)
	}
	drop_fn := cast(proc(el: rawptr))DROP_FN
	type := _Type {
		id       = T,
		ptr_id   = typeid_of(^T),
		size     = size_of(T),
		align    = align_of(T),
		drop     = drop_fn,
		clone    = clone_fn,
		bit_mask = 2 << u64(this.types_len),
	}
	_add_type(this, type)
}
_drop_range :: proc(this: ^MultiHistory, start_idx: int, len: int) {
	assert(len <= this.past_len + this.future_len)
	assert(len <= this.cap)
	types := _access_types(this)
	for i in 0 ..< len {
		idx := (start_idx + i) % this.cap
		_snapshot_drop(&this.snapshots[idx], types)
	}
}
multi_history_drop :: proc(this: ^MultiHistory) {
	_drop_range(this, this.first_past_idx, this.past_len + this.future_len)
}
// Note: call with values directly, e.g. multi_history_snapshot(&h, players, world)
multi_history_snapshot :: proc(this: ^MultiHistory, value_anys: ..any) {
	assert(_anys_are_unique(value_anys))

	// remove the future when snapshot, such that redo is not possible anymore
	_drop_range(this, this.first_past_idx + this.past_len, this.future_len)
	this.future_len = 0

	slot := &this.snapshots[(this.first_past_idx + this.past_len) % this.cap]
	types := _access_types(this)
	if this.past_len < this.cap {
		this.past_len += 1
	} else {
		// drop the snapshot at the top_stack_idx because it is overwritten:
		_snapshot_drop(slot, types)
		this.first_past_idx = (this.first_past_idx + 1) % this.cap
	}

	assert(slot.alloc_ptr == nil)
	slot^ = _snapshot_create(types, value_anys)
}
// Note: call with pointers to values, e.g. multi_history_snapshot(&h, &players, &world), ptrs can be in any order, but need to be present for any type that could have been saved in snapshots
multi_history_undo :: proc(this: ^MultiHistory, value_ptr_anys: ..any) -> (success: bool) {
	if this.past_len == 0 do return false
	assert(_anys_are_unique(value_ptr_anys))
	this.past_len -= 1
	this.future_len += 1
	snapshot := &this.snapshots[(this.first_past_idx + this.past_len) % this.cap]
	_snapshot_swap_with_state(snapshot, _access_types(this), value_ptr_anys)
	return true
}
// Note: call with pointers to values, e.g. multi_history_snapshot(&h, &players, &world), ptrs can be in any order, but need to be present for any type that could have been saved in snapshots
multi_history_redo :: proc(this: ^MultiHistory, value_ptr_anys: ..any) -> (success: bool) {
	if this.future_len == 0 do return false
	assert(_anys_are_unique(value_ptr_anys))
	snapshot := &this.snapshots[(this.first_past_idx + this.past_len) % this.cap]
	_snapshot_swap_with_state(snapshot, _access_types(this), value_ptr_anys)
	this.past_len += 1
	this.future_len -= 1
	return true
}
_snapshot_swap_with_state :: proc(this: ^_Snapshot, types: []_Type, value_ptr_anys: []any) {
	iter := _iter(this, types)
	outer: for {
		alloc_field_ptr, type := _next(&iter) or_break
		for a in value_ptr_anys {
			if a.id == type.ptr_id {
				// this is the right type
				state_ptr := (cast(^rawptr)a.data)^ // dereference the ^^T in the any
				slice.ptr_swap_non_overlapping(alloc_field_ptr, state_ptr, type.size)
				continue outer
			}
		}
		panic(tprint("no value of type", type.id, "found in the provided value_ptr_anys"))
	}
}
_SnapshotIter :: struct {
	bit_mask: u64,
	types:    []_Type,
	cur_ptr:  rawptr,
	cur_bit:  u64,
	ty_idx:   u64,
}
_iter :: proc(this: ^_Snapshot, types: []_Type) -> _SnapshotIter {
	return _SnapshotIter {
		bit_mask = this.bit_mask,
		types = types,
		cur_ptr = this.alloc_ptr,
		ty_idx = 0,
	}
}
_next :: proc(iter: ^_SnapshotIter) -> (val_ptr: rawptr, type: ^_Type, ok: bool) {
	for {
		iter.cur_bit = 2 << iter.ty_idx
		if iter.cur_bit > iter.bit_mask {
			return nil, nil, false
		}
		if iter.cur_bit & iter.bit_mask == 0 {
			iter.ty_idx += 1 // continue loop until bits too high or type with 1 bit is found
		} else {
			break
		}
	}
	type = &iter.types[iter.ty_idx]
	iter.cur_ptr = mem.align_forward(iter.cur_ptr, uintptr(type.align))
	val_ptr = iter.cur_ptr
	iter.cur_ptr = rawptr(uintptr(iter.cur_ptr) + uintptr(type.size))
	iter.ty_idx += 1
	return val_ptr, type, true
}
_anys_are_unique :: proc(anys: []any) -> bool {
	for a, i in anys {
		for b in anys[i + 1:] {
			if a.id == b.id {
				return false
			}
		}
	}
	return true
}
