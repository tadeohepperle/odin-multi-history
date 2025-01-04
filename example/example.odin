package example


import history "../"

import "core:fmt"
import "core:slice"
print :: fmt.println
space_print :: proc(args: ..any) {
	print("\n")
	print(..args)
	print("\n")

}

IVec2 :: [2]int
PlayerId :: distinct u32
State :: struct {
	players:   Players,
	positions: Positions,
	world:     World,
}
Players :: struct {
	waiting: [dynamic]PlayerId,
	ingame:  [dynamic]PlayerId,
}
World :: enum {
	Europe,
	Asia,
	America,
}
Positions :: map[PlayerId]IVec2

players_clone :: proc(this: Players) -> (res: Players) {
	print("        clone players: ", this)
	res.ingame = slice.clone_to_dynamic(this.ingame[:])
	res.waiting = slice.clone_to_dynamic(this.waiting[:])
	return res
}
players_drop :: proc(this: ^Players) {
	print("        drop players: ", this)
	delete(this.ingame)
	delete(this.waiting)
}
positions_clone :: proc(this: Positions) -> (res: Positions) {
	print("        clone positions: ", this)
	for k, v in this {
		res[k] = v
	}
	return res
}
positions_drop :: proc(this: ^Positions) {
	print("        drop positions: ", this)
	delete(this^)
}

main :: proc() {
	// /////////////////////////////////////////////////////////////////////////////
	// Setup: 

	state: State
	h: history.MultiHistory // will track changes for world, players and positions

	// add tracks with dedicated clone/drop functions for players and positions
	history.multi_history_add_track(&h, Players, players_clone, players_drop)
	history.multi_history_add_track(&h, Positions, positions_clone, positions_drop)
	// add track for plain old data type World :: [4][4]Tile
	history.multi_history_add_track(&h, World)
	// multi_history_initialize allocated the backing buffers, specifying max 3 undo steps
	history.multi_history_initialize(&h, 3)

	// /////////////////////////////////////////////////////////////////////////////
	// Modify the state, by adding 5 waiting players:
	space_print("Add 5 waiting players:")
	for player_id in ([]PlayerId{101, 102, 103, 104, 105}) {
		print("    history.multi_history_snapshot")
		history.multi_history_snapshot(&h, state.players)
		append(&state.players.waiting, player_id)
		print("      state: ", state)
	}
	space_print(
		"You can see that the last two times, a players was dropped, because the buffer wraps around and has only place for the last 3 states\nTry to undo 5 times:",
	)
	for _ in 0 ..< 5 {
		// here you have to provide all states tracked by the multi-history
		print("    history.multi_history_undo")
		success := history.multi_history_undo(&h, &state.players, &state.positions, &state.world)
		print("    success:", success)
		print("      state: ", state)
	}
	assert(len(state.players.waiting) == 2)
	space_print(
		"The last 2 out of the 5 undos were unsuccessful because only 4 past states are saved\nRedo 3 times to get up to 5 players again:",
	)
	// redo all 3 saved past states to get up to our 5 players:
	for _ in 0 ..< 3 {
		print("    history.multi_history_redo")
		success := history.multi_history_redo(&h, &state.players, &state.positions, &state.world)
		assert(success)
		print("      state: ", state)
	}
	assert(len(state.players.waiting) == 5)
	// this should only be possible 3 times, the 4th time would fail:
	assert(!history.multi_history_redo(&h, &state.players, &state.positions, &state.world))

	space_print(
		"This worked we are back up to our 5 waiting players. Lets undo 2 times to get back down to 3 players, such that we can see how another snapshot discards the future afterwards",
	)
	for _ in 0 ..< 2 {
		print("    history.multi_history_undo")
		success := history.multi_history_undo(&h, &state.players, &state.positions, &state.world)
		assert(success)
		print("      state: ", state)
	}


	// modify players and player positions at the same time:
	space_print("Now we move player 103 to ingame and set his position to {7,7}")
	print("    history.multi_history_snapshot")
	history.multi_history_snapshot(&h, state.players, state.positions)
	player_103 := pop(&state.players.waiting)
	assert(player_103 == 103)
	append(&state.players.ingame, player_103)
	state.positions[player_103] = {7, 7}
	print("      state: ", state)
	space_print(
		"Note the drop calls throwing away the 2 future states that were created by the last 2 undos\nNow set the world to Asia 5 times:",
	)
	for i in 0 ..< 5 {
		print("    history.multi_history_snapshot")
		history.multi_history_snapshot(&h, state.world)
		state.world = .Asia
		print("      state: ", state)
	}


}
