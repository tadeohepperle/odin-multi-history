package example

import history "../"

import "core:fmt"
import "core:slice"
print :: fmt.println

main :: proc() {
	state := make([]int, 5)
	drop_fn := proc(s: []int) -> []int {
		return slice.clone(s)
	}
	clone_fn := proc(s: ^[]int) {
		delete(s^)
	}
	hist := history.single_history_create([]int, drop_fn, clone_fn)

	history.single_history_snapshot(&hist, state)
	for i in 0 ..< 10 {
		history.single_history_snapshot(&hist, state)
		delete(state)
		state = make([]int, i)
		for &el, i in state {
			el = i * 10
		}
		print(state)
	}

	history.single_history_undo(&hist, &state)
	history.single_history_undo(&hist, &state)
	history.single_history_undo(&hist, &state)
	print(state)

	history.single_history_redo(&hist, &state)
	history.single_history_redo(&hist, &state)
	print(state)

	history.single_history_drop(&hist)
	delete(state)
}
