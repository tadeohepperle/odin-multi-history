package history

import "core:container/queue"
import "core:slice"

SingleHistory :: struct($T: typeid) {
	past:     queue.Queue(LabeledState(T)), // stack for undo (queue to easily trim the oldest elements)
	future:   [dynamic]LabeledState(T), // stack, for redo
	max_size: int,
	clone_fn: proc(t: T) -> T, // nillable
	drop_fn:  proc(t: ^T), // nillable
}
LabeledState :: struct($T: typeid) {
	label: string, // Note: expected to be static string!!
	state: T,
}
single_history_len :: proc(this: SingleHistory($T)) -> (past_size: int, future_size: int) {
	return queue.len(this.past), len(this.future)
}
single_history_drop :: proc(this: ^SingleHistory($T)) {
	if this.drop_fn != nil {
		for &fut in this.future {
			this.drop_fn(&fut.state)
		}
		for queue.len(this.past) > 0 {
			removed := queue.pop_back(&this.past)
			this.drop_fn(&removed.state)
		}
	}
	delete(this.future)
	queue.destroy(&this.past)
}

single_history_create :: proc(
	$T: typeid,
	clone_fn: proc(t: T) -> T,
	drop_fn: proc(t: ^T),
) -> SingleHistory(T) {
	return SingleHistory(T){max_size = 128, clone_fn = clone_fn, drop_fn = drop_fn}
}

// saves the state state to the past, such that it can be modified afterwards, with the possibility to return to it later.
// 
// Note: assumes that the "label" is a static string!!! is not freed or managed otherwise.
single_history_snapshot :: proc(this: ^SingleHistory($T), state: T, label: string = "unknown") {
	if this.max_size <= 0 {
		return
	}
	past_state: LabeledState(T) = {label, state if this.clone_fn == nil else this.clone_fn(state)}
	queue.push_back(&this.past, past_state)
	_trim_to_max_size(this)

	// after snapshot, the future queue is erased, no "redo" possible anymore
	if this.drop_fn != nil {
		for &fut in this.future {
			this.drop_fn(&fut.state)
		}
	}
	clear(&this.future)
}
single_history_undo :: proc(this: ^SingleHistory($T), state: ^T) -> (label: string, ok: bool) {
	if queue.len(this.past) == 0 {
		return "", false
	}

	state_before_undo := state^
	target := queue.pop_back(&this.past)
	state^ = target.state
	append(&this.future, LabeledState(T){target.label, state_before_undo})
	return target.label, true
}
single_history_redo :: proc(this: ^SingleHistory($T), state: ^T) -> (label: string, ok: bool) {
	if len(this.future) == 0 {
		return "", false
	}

	state_before_redo := state^
	target := pop(&this.future)
	state^ = target.state
	queue.push_back(&this.past, LabeledState(T){target.label, state_before_redo})
	_trim_to_max_size(this)
	return target.label, true
}
_trim_to_max_size :: proc(this: ^SingleHistory($T)) {
	if queue.len(this.past) > this.max_size {
		removed_bc_too_old := queue.pop_front(&this.past)
		if this.drop_fn != nil {
			this.drop_fn(&removed_bc_too_old.state)
		}
	}
}
