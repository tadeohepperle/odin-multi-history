package main

import "core:fmt"
import "core:mem"
import "core:slice"
print :: fmt.println
tprint :: fmt.tprint

main :: proc() {
	num: int = 3
	str := "Hey, whats up"

	h: MultiHistory
	multi_history_add_track(&h, int)
	multi_history_add_track(&h, string)
	multi_history_initialize(&h, 3)

	multi_history_snapshot(&h, &str)
	// num = 3838
	str = "lololol"
	str = "lololol"
	str = "lololol"
	str = "lololol"
	fmt.printfln("snapshot, afterwards num = %i, str = %s", num, str)

	for &track, i in h.tracks[:h.tracks_len] {
		print(i, _track_to_string(&track))
	}
	assert(multi_history_undo(&h, &num, &str))
	fmt.printfln("undo, afterwards num = %i, str = %s", num, str)
	multi_history_redo(&h, &num, &str)
	fmt.printfln("redo, afterwards num = %i, str = %s", num, str)
}

HISTORY_MAX_TRACKS :: size_of(u64) * 8
MultiHistory :: struct {
	tracks:           [HISTORY_MAX_TRACKS]_Track,
	tracks_len:       int,
	is_initialized:   bool,
	bit_mask_history: []u64, // should have len == cap, a history of which tracks got affected by the change
	cap:              int,
	first_p_idx:      int,
	p_len:            int,
	f_len:            int,
}
multi_history_info :: proc(this: MultiHistory) -> (past_len: int, future_len: int, cap: int) {
	return this.p_len, this.f_len, this.cap
}
multi_history_add_track :: proc {
	multi_history_add_track_for_copy_types,
	multi_history_add_track_for_managed_types,
}
multi_history_add_track_for_copy_types :: proc(this: ^MultiHistory, $T: typeid) {
	track := _Track {
		ty      = T,
		ptr_ty  = typeid_of(^T),
		ty_size = size_of(T),
		drop    = nil,
		clone   = nil,
	}
	_add_track(this, track)
}
multi_history_add_track_for_managed_types :: proc(
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
	track := _Track {
		ty      = T,
		ptr_ty  = typeid_of(^T),
		ty_size = size_of(T),
		drop    = drop_fn,
		clone   = clone_fn,
	}
	_add_track(this, track)
}
@(private)
_add_track :: proc(this: ^MultiHistory, track: _Track) {
	assert(!this.is_initialized)
	assert(this.tracks_len < HISTORY_MAX_TRACKS)
	for other_track in this.tracks[:this.tracks_len] {
		assert(other_track.ty != track.ty) // only one track should have this type!
	}
	assert(track.ty_size != 0)
	this.tracks[this.tracks_len] = track
	this.tracks_len += 1

}
multi_history_initialize :: proc(this: ^MultiHistory, cap: int) {
	assert(!this.is_initialized)
	this.is_initialized = true
	this.cap = cap
	this.bit_mask_history = make([]u64, cap)
	for &track in this.tracks[:this.tracks_len] {
		track.cap = cap
		buf_size := track.ty_size * cap
		ptr, err := mem.alloc(buf_size)
		assert(err == .None)
		track.buffer = ptr
	}
}
multi_history_drop :: proc(this: ^MultiHistory) {
	assert(this.is_initialized)
	for &track in this.tracks[:this.tracks_len] {
		_track_drop_range(&track, 0, this.p_len + this.f_len)
		mem.free(track.buffer)
	}
	delete(this.bit_mask_history)
}
_track_bit_mask :: proc(track_idx: int) -> u64 {
	return 2 << u64(track_idx)
}
// Note: call with values directly, e.g. multi_history_snapshot(&h, players, world)
multi_history_snapshot :: proc(this: ^MultiHistory, state_of_some_tracks: ..any) {
	assert(this.is_initialized)
	bit_mask: u64 = 0
	outer: for p, i in state_of_some_tracks {
		for &track, track_idx in this.tracks[:this.tracks_len] {
			if track.ty != p.id do continue
			bit_mask |= _track_bit_mask(track_idx)
			_track_snapshot(&track, p.data)
			continue outer
		}
		panic(fmt.tprint("could not find track for ty", type_info_of(p.id)))
	}
	this.f_len = 0
	top_stack_idx := (this.first_p_idx + this.p_len) %% this.cap
	if this.p_len < this.cap {
		this.p_len += 1
	} else {
		this.first_p_idx = (this.first_p_idx + 1) %% this.cap
	}
	this.bit_mask_history[top_stack_idx] = bit_mask
}

// sanity check that the any values are all ptrs to values of the added tracks
_assert_all_state_ptrs_match_tracks :: proc(this: ^MultiHistory, state_ptrs_all_tracks: []any) {
	assert(this.is_initialized)
	assert(len(state_ptrs_all_tracks) == this.tracks_len)
	for p, i in state_ptrs_all_tracks {
		track := this.tracks[i]
		assert(p.id == track.ptr_ty)
	}
}
// Note: call with pointers to values, e.g. multi_history_snapshot(&h, &players, &world), ptrs must be in the same order as the tracks that were added to the history
multi_history_undo :: proc(this: ^MultiHistory, state_ptrs_all_tracks: ..any) -> (success: bool) {
	_assert_all_state_ptrs_match_tracks(this, state_ptrs_all_tracks)
	if this.p_len == 0 {
		return false
	}
	this.p_len -= 1
	this.f_len += 1
	bitmask := this.bit_mask_history[(this.first_p_idx + this.p_len) %% this.cap]
	for p, i in state_ptrs_all_tracks {
		if (bitmask & _track_bit_mask(i)) == 0 do continue
		data_ptr := (cast(^rawptr)p.data)^ // dereference the ^^T in the any
		_track_undo(&this.tracks[i], data_ptr)
	}
	return true
}
// Note: call with pointers to values, e.g. multi_history_snapshot(&h, &players, &world),ptrs must be in the same order as the tracks that were added to the history
multi_history_redo :: proc(this: ^MultiHistory, state_ptrs_all_tracks: ..any) -> (success: bool) {
	_assert_all_state_ptrs_match_tracks(this, state_ptrs_all_tracks)
	if this.f_len == 0 {
		return false
	}
	bitmask := this.bit_mask_history[(this.first_p_idx + this.p_len) %% this.cap]
	this.p_len += 1
	this.f_len -= 1
	for p, i in state_ptrs_all_tracks {
		if (bitmask & _track_bit_mask(i)) == 0 do continue
		data_ptr := (cast(^rawptr)p.data)^ // dereference the ^^T in the any
		_track_redo(&this.tracks[i], data_ptr)
	}
	return true
}

// contains the events like this:
// [p,p,p,p,f,f,f,0,0,0,0] where p stands for past event, f for future event (undone before) and 0 is uninitialized/unused.
// note that this is a wrap-around buffer, where first_p_idx describes where p...,f... starts.
_Track :: struct {
	ptr_ty:      typeid, // = ^T
	ty:          typeid, // = T
	ty_size:     int,
	drop:        proc(el: rawptr),
	clone:       proc(src: rawptr, dst: rawptr),
	buffer:      rawptr, // = []T with cap as length, so size of buffer is `cap * size_of(ty)`
	cap:         int, // num elements that fit in buffer
	p_len:       int, // number of past states
	f_len:       int, // number of future states
	first_p_idx: int, //points at first past event
}
// swap state and last past, then this slot (containing the (input arg) state) becomes the first future
_track_undo :: proc(this: ^_Track, state: rawptr) {
	assert(this.p_len > 0)
	this.p_len -= 1
	this.f_len += 1
	slot_ptr := _track_ptr_at_idx(this, this.first_p_idx + this.p_len)
	slice.ptr_swap_non_overlapping(slot_ptr, state, this.ty_size)
}
_track_redo :: proc(this: ^_Track, state: rawptr) {
	assert(this.f_len > 0)
	slot_ptr := _track_ptr_at_idx(this, this.first_p_idx + this.p_len)
	slice.ptr_swap_non_overlapping(slot_ptr, state, this.ty_size)
	this.f_len -= 1
	this.p_len += 1
}
_track_snapshot :: proc(this: ^_Track, state: rawptr) {
	_track_drop_range(this, this.first_p_idx + this.p_len, this.f_len)
	this.f_len = 0
	slot_ptr := _track_ptr_at_idx(this, this.first_p_idx + this.p_len)
	// if at capacity, shift the start by one to the right and drop the element in the cell that is now overwritten
	if this.p_len < this.cap {
		this.p_len += 1
	} else {
		assert(slot_ptr == _track_ptr_at_idx(this, this.first_p_idx))
		this.first_p_idx += 1
		this.first_p_idx %= this.cap // loop it around
		if this.drop != nil {
			this.drop(slot_ptr)
		}
	}
	// copy new data into slot
	if this.clone == nil {
		mem.copy_non_overlapping(slot_ptr, state, this.ty_size)
	} else {
		this.clone(state, slot_ptr)
	}
}
_track_to_string :: proc(this: ^_Track) -> string {
	past := make([]any, this.p_len, context.temp_allocator)
	future := make([]any, this.f_len, context.temp_allocator)
	for i in 0 ..< this.p_len {
		past[i] = mem.make_any(_track_ptr_at_idx(this, this.first_p_idx + i), this.ty)
	}
	first_f_idx := this.first_p_idx + this.p_len
	for i in 0 ..< this.f_len {
		future[i] = mem.make_any(_track_ptr_at_idx(this, first_f_idx + i), this.ty)
	}
	return fmt.tprint(
		"HistoryTrack{ ty: ",
		this.ty,
		", past: ",
		past,
		", future: ",
		future,
		"}",
		sep = "",
	)
}
// Note: start_idx may be out of range, it is taken % cap anyway
_track_drop_range :: proc(this: ^_Track, start_idx: int, n: int) {
	if this.drop == nil {
		return
	}
	assert(start_idx >= 0)
	assert(n <= this.cap)
	assert(n <= this.p_len + this.f_len)
	buf_start := uintptr(this.buffer)
	for i in 0 ..< n {
		this.drop(_track_ptr_at_idx(this, start_idx + i))
	}
}
// Note: idx can be out of range
_track_ptr_at_idx :: proc(this: ^_Track, idx: int) -> rawptr {
	offset := (idx % this.cap) * this.ty_size
	return rawptr(uintptr(this.buffer) + uintptr(offset))
}
