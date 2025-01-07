package history

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"
print :: fmt.println
tprint :: fmt.tprint
import "base:runtime"

// The MultiHistory supports up to 64 different types
MAX_TYPE_COUNT :: size_of(u64) * 8

// /////////////////////////////////////////////////////////////////////////////
// SECTION: Semi-Static Multi History storing parts of an upfront specified Fixed Type Ptrs struct
// /////////////////////////////////////////////////////////////////////////////

MultiHistory :: struct($T: typeid) {
	using inner: _Inner,
	struct_ty:   runtime.Type_Info_Struct,
}
multi_history_create :: proc($S: typeid, cap: int) -> MultiHistory(S) {
	inner := _Inner {
		cap       = cap,
		snapshots = make([]_Snapshot, cap),
	}
	t_info := runtime.type_info_base(type_info_of(S))

	stru: runtime.Type_Info_Struct
	ok: bool
	if stru, ok = t_info.variant.(runtime.Type_Info_Struct); !ok {
		panic(fmt.tprintf("type %v is not a struct", typeid_of(S)))
	}
	for f_idx in 0 ..< stru.field_count {
		f_ty_info := runtime.type_info_base(stru.types[f_idx])
		ptr_ty: runtime.Type_Info_Pointer
		if ptr_ty, ok = f_ty_info.variant.(runtime.Type_Info_Pointer); !ok {
			panic(fmt.tprintf("field %v: %v is not ptr type", stru.names[f_idx], f_ty_info.id))
		}
		val_ty := ptr_ty.elem
		type := _Type {
			id     = val_ty.id,
			ptr_id = f_ty_info.id,
			size   = val_ty.size,
			align  = val_ty.align,
			drop   = nil,
			clone  = nil,
		}
		_inner_add_type(&inner, type)
	}
	assert(size_of(S) == int(stru.field_count) * size_of(rawptr))
	assert(stru.field_count <= 64, "struct field count needs to be < 64 for bit masks to work")
	return MultiHistory(S){inner, stru}
}
multi_history_drop :: proc(this: ^_Inner) {
	_inner_drop_range(this, this.first_past_idx, this.past_len + this.future_len)
}
multi_history_info :: proc(this: DynamicHistory) -> (past_len: int, future_len: int, cap: int) {
	return this.past_len, this.future_len, this.cap
}
// The CLONE_FN needs to be a parapoly const, because of the transformation into proc(rawptr,rawptr)
multi_history_set_type_functions :: proc(
	this: ^MultiHistory($S),
	field_name: string,
	$T: typeid,
	$CLONE_FN: proc(_: T) -> T,
	drop_fn: proc(_: ^T),
) {
	assert(this.types_len == int(this.struct_ty.field_count))
	for f_idx in 0 ..< this.struct_ty.field_count {
		if this.struct_ty.names[f_idx] != field_name do continue
		ptr_t_ty := this.struct_ty.types[f_idx]
		ptr_ty_info :=
			ptr_t_ty.variant.(runtime.Type_Info_Pointer) or_else panic("should be ptr ty")
		assert(ptr_ty_info.elem.id == typeid_of(T))
		ty := &this.types[f_idx]
		ty.clone = proc(src, dst: rawptr) {
			src_t := cast(^T)src
			dst_t := cast(^T)dst
			dst_t^ = CLONE_FN(src_t^)
		}
		ty.drop = cast(proc(el: rawptr))drop_fn
		return
	}
	panic(
		fmt.tprintf("no field %s: %v found in struct %v", field_name, typeid_of(T), typeid_of(S)),
	)
}
multi_history_snapshot :: proc(this: ^MultiHistory($S), ptrs: S, label: Maybe(string) = nil) {
	ptrs := ptrs
	field_ptrs := slice.from_ptr(cast(^rawptr)&ptrs, int(this.struct_ty.field_count))
	snapshot, ok := _snapshot_create_from_ptrs_struct(
		this.types[:this.types_len],
		field_ptrs,
		label,
	)
	if !ok {
		return
	}
	_inner_add_snapshot(&this.inner, snapshot, label)
}
// Note: call with pointers to values, e.g. multi_history_snapshot(&h, &players, &world), ptrs can be in any order, but need to be present for any type that could have been saved in snapshots
multi_history_undo :: proc(this: ^MultiHistory($S), ptrs: S) -> (success: bool) {
	if this.past_len == 0 do return false
	ptrs := ptrs
	field_ptrs := slice.from_ptr(cast(^rawptr)&ptrs, int(this.struct_ty.field_count))
	for ptr in field_ptrs {
		assert(ptr != nil) // all ptrs should point somewhere, no nil ptrs!
	}
	this.past_len -= 1
	this.future_len += 1
	snapshot := &this.snapshots[(this.first_past_idx + this.past_len) % this.cap]
	_snapshot_swap_with_state_field_ptrs(snapshot, _inner_types(this), field_ptrs)
	return true
}
// Note: call with pointers to values, e.g. multi_history_snapshot(&h, &players, &world), ptrs can be in any order, but need to be present for any type that could have been saved in snapshots
multi_history_redo :: proc(this: ^MultiHistory($S), ptrs: S) -> (success: bool) {
	if this.future_len == 0 do return false
	ptrs := ptrs
	field_ptrs := slice.from_ptr(cast(^rawptr)&ptrs, int(this.struct_ty.field_count))
	for ptr in field_ptrs {
		assert(ptr != nil) // all ptrs should point somewhere, no nil ptrs!
	}
	snapshot := &this.snapshots[(this.first_past_idx + this.past_len) % this.cap]
	_snapshot_swap_with_state_field_ptrs(snapshot, _inner_types(this), field_ptrs)
	this.past_len += 1
	this.future_len -= 1
	return true
}
_snapshot_swap_with_state_field_ptrs :: proc(
	this: ^_Snapshot,
	types: []_Type,
	field_ptrs: []rawptr,
) {
	// note: this.label does not change
	assert(len(types) == len(field_ptrs))
	iter := _iter(this, types)
	for {
		alloc_field_ptr, type := _next(&iter) or_break
		field_ptr := field_ptrs[type.idx]
		slice.ptr_swap_non_overlapping(alloc_field_ptr, field_ptr, type.size)
	}
}
// values are direct values made into anys, such that any.data is assumed to be ^T
_snapshot_create_from_ptrs_struct :: proc(
	types: []_Type,
	field_ptrs: []rawptr,
	label: Maybe(string),
) -> (
	snapshot: _Snapshot,
	ok: bool,
) {
	assert(len(types) == len(field_ptrs))
	bit_mask: u64
	total_size: int
	for ty, f_idx in types {
		if field_ptrs[f_idx] == nil do continue
		bit_mask |= 2 << u64(f_idx)
		total_size = mem.align_forward_int(total_size, ty.align)
		total_size += ty.size
	}
	if total_size == 0 {
		return {}, false
	}
	alloc_ptr, err := mem.alloc(total_size)
	assert(err == .None)
	// copy data over into the allocation
	cur_ptr := alloc_ptr
	last_bit_mask: u64 = 0
	for ty, f_idx in types {
		field_ptr := field_ptrs[f_idx]
		if field_ptr == nil do continue
		assert(ty.bit_mask > last_bit_mask)
		last_bit_mask = ty.bit_mask
		cur_ptr = mem.align_forward(cur_ptr, uintptr(ty.align))
		if ty.clone == nil {
			mem.copy_non_overlapping(cur_ptr, field_ptr, ty.size)
		} else {
			ty.clone(field_ptr, cur_ptr)
		}
		cur_ptr = rawptr(uintptr(cur_ptr) + uintptr(ty.size))
	}
	label_owned: Maybe(string)
	if label, ok := label.(string); ok {
		label_owned = strings.clone(label)
	}
	return _Snapshot{bit_mask, total_size, alloc_ptr, label_owned}, true
}


// /////////////////////////////////////////////////////////////////////////////
// SECTION:  Dynamic Multi-history with type punning
// /////////////////////////////////////////////////////////////////////////////
DynamicHistory :: struct {
	using inner: _Inner,
}
dynamic_history_create :: proc(cap: int) -> DynamicHistory {
	return DynamicHistory{inner = _Inner{cap = cap, snapshots = make([]_Snapshot, cap)}}
}
dynamic_history_drop :: proc(this: ^DynamicHistory) {
	_inner_drop_range(this, this.first_past_idx, this.past_len + this.future_len)
}
dynamic_history_info :: proc(this: DynamicHistory) -> (past_len: int, future_len: int, cap: int) {
	return this.past_len, this.future_len, this.cap
}
dynamic_history_add_type :: proc {
	dynamic_history_add_copy_type,
	dynamic_history_add_managed_type,
}
dynamic_history_add_copy_type :: proc(this: ^DynamicHistory, $T: typeid) {
	type := _Type {
		id     = T,
		ptr_id = typeid_of(^T),
		size   = size_of(T),
		align  = align_of(T),
		drop   = nil,
		clone  = nil,
	}
	_inner_add_type(this, type)
}
dynamic_history_add_managed_type :: proc(
	this: ^DynamicHistory,
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
		id     = T,
		ptr_id = typeid_of(^T),
		size   = size_of(T),
		align  = align_of(T),
		drop   = drop_fn,
		clone  = clone_fn,
	}
	_inner_add_type(this, type)
}
// Note: call with values directly, e.g. dynamic_history_snapshot(&h, players, world)
dynamic_history_snapshot :: proc(
	this: ^DynamicHistory,
	value_anys: ..any,
	label: Maybe(string) = nil,
) {
	assert(_anys_are_unique(value_anys))
	assert(len(value_anys) > 0)
	snapshot := _snapshot_create_from_any_values(_inner_types(this), value_anys, label)
	_inner_add_snapshot(&this.inner, snapshot, label)
}
// Note: call with pointers to values, e.g. multi_history_snapshot(&h, &players, &world), ptrs can be in any order, but need to be present for any type that could have been saved in snapshots
dynamic_history_undo :: proc(this: ^DynamicHistory, value_ptr_anys: ..any) -> (success: bool) {
	if this.past_len == 0 do return false
	assert(_anys_are_unique(value_ptr_anys))
	this.past_len -= 1
	this.future_len += 1
	snapshot := &this.snapshots[(this.first_past_idx + this.past_len) % this.cap]
	_snapshot_swap_with_state_any_ptrs(snapshot, _inner_types(this), value_ptr_anys)
	return true
}
// Note: call with pointers to values, e.g. multi_history_snapshot(&h, &players, &world), ptrs can be in any order, but need to be present for any type that could have been saved in snapshots
dynamic_history_redo :: proc(this: ^DynamicHistory, value_ptr_anys: ..any) -> (success: bool) {
	if this.future_len == 0 do return false
	assert(_anys_are_unique(value_ptr_anys))
	snapshot := &this.snapshots[(this.first_past_idx + this.past_len) % this.cap]
	_snapshot_swap_with_state_any_ptrs(snapshot, _inner_types(this), value_ptr_anys)
	this.past_len += 1
	this.future_len -= 1
	return true
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
_snapshot_create_from_any_values :: proc(
	types: []_Type,
	value_anys: []any,
	label: Maybe(string),
) -> _Snapshot {
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
	label_owned: Maybe(string)
	if label, ok := label.(string); ok {
		label_owned = strings.clone(label)
	}
	return _Snapshot{bit_mask, total_size, alloc_ptr, label_owned}
}
_snapshot_swap_with_state_any_ptrs :: proc(
	this: ^_Snapshot,
	types: []_Type,
	value_ptr_anys: []any,
) {
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
	// note: this.label stays the same
}


// /////////////////////////////////////////////////////////////////////////////
// SECTION: Shared implementation
// /////////////////////////////////////////////////////////////////////////////

_Inner :: struct {
	types:          [MAX_TYPE_COUNT]_Type,
	types_len:      int,
	snapshots:      []_Snapshot, // should have len == cap, a history of which tracks got affected by the change
	cap:            int,
	first_past_idx: int, // marks start of p,p,p,p,f,f where p are past snapshots and f future snapshots
	past_len:       int,
	future_len:     int,
}
_inner_add_snapshot :: proc(this: ^_Inner, snapshot: _Snapshot, label: Maybe(string) = nil) {
	// remove the future when snapshot, such that redo is not possible anymore
	_inner_drop_range(this, this.first_past_idx + this.past_len, this.future_len)
	this.future_len = 0
	slot := &this.snapshots[(this.first_past_idx + this.past_len) % this.cap]
	types := this.types[:this.types_len]
	if this.past_len < this.cap {
		this.past_len += 1
	} else {
		// drop the snapshot at the top_stack_idx because it is overwritten:
		_snapshot_drop(slot, types)
		this.first_past_idx = (this.first_past_idx + 1) % this.cap
	}
	assert(slot.alloc_ptr == nil)
	slot^ = snapshot
}

_Type :: struct {
	ptr_id:   typeid, // = ^T
	id:       typeid, // = T
	size:     int,
	align:    int,
	drop:     proc(el: rawptr),
	clone:    proc(src: rawptr, dst: rawptr),
	idx:      int,
	bit_mask: u64, // = 2 << idx of this type in types array
}
// the ptr points to an allocation that contains the types specified in 
_Snapshot :: struct {
	bit_mask:   u64,
	total_size: int, // size of allocation at ptr
	alloc_ptr:  rawptr,
	label:      Maybe(string),
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
	if label, ok := this.label.(string); ok {
		delete(label)
	}
	this^ = _Snapshot{} // zero out memory
}
_inner_types :: proc(this: ^_Inner) -> []_Type {
	return this.types[:this.types_len]
}
_inner_add_type :: proc(this: ^_Inner, type: _Type) {
	assert(this.types_len < MAX_TYPE_COUNT)
	slot := &this.types[this.types_len]
	slot^ = type
	slot.idx = this.types_len
	slot.bit_mask = 2 << u64(this.types_len)
	this.types_len += 1
}
_inner_drop_range :: proc(this: ^_Inner, start_idx: int, len: int) {
	assert(len <= this.past_len + this.future_len)
	assert(len <= this.cap)
	types := _inner_types(this)
	for i in 0 ..< len {
		idx := (start_idx + i) % this.cap
		_snapshot_drop(&this.snapshots[idx], types)
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
