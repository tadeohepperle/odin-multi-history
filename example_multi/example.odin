package example


import history "../"

import "core:fmt"
import "core:slice"
print :: fmt.println

set_functions :: history.multi_history_set_type_functions
snapshot :: history.multi_history_snapshot
undo :: history.multi_history_undo
redo :: history.multi_history_redo

main :: proc() {
	players: Players
	positions: Positions
	world: World
	i, j, k: int

	// setup the ptrs that point at the different parts of the game state
	state_ptrs := StatePtrs{&players, &positions, &world, &i, &j, &k}

	// create new history saving the last 3 snapshotted states.
	h := history.multi_history_create(StatePtrs, 3)
	// add dedicated clone/drop functions for players and positions, the other types are simple copy types
	set_functions(&h, "players", Players, players_clone, players_drop)
	set_functions(&h, "positions", Positions, positions_clone, positions_drop)

	// Modify the state, by adding 5 waiting players:
	print(cast(rawptr)&players, "raw ptr")
	space_print("Add 5 waiting players:")
	for player_id in ([]PlayerId{101, 102, 103, 104, 105}) {
		print("    snapshot")
		snapshot(&h, StatePtrs{players = &players}) // only players are saved, not the other parts of the state
		append(&players.waiting, player_id)
		print_state(state_ptrs)
	}
	space_print(
		"You can see that the last two times, a players was dropped, because the buffer wraps around and has only place for the last 3 states\nTry to undo 5 times:",
	)
	for _ in 0 ..< 5 {
		// here you have to provide all states tracked by the multi-history
		print("    undo")
		success := undo(&h, state_ptrs)
		print("    success:", success)
		print_state(state_ptrs)
	}
	assert(len(players.waiting) == 2)
	space_print(
		"The last 2 out of the 5 undos were unsuccessful because only 4 past states are saved\nRedo 3 times to get up to 5 players again:",
	)
	// redo all 3 saved past states to get up to our 5 players:
	for _ in 0 ..< 3 {
		print("    redo")
		success := redo(&h, state_ptrs)
		assert(success)
		print_state(state_ptrs)
	}
	assert(len(players.waiting) == 5)
	// this should only be possible 3 times, the 4th time would fail:
	assert(!redo(&h, state_ptrs))

	space_print(
		"This worked we are back up to our 5 waiting players. Lets undo 2 times to get back down to 3 players, such that we can see how another snapshot discards the future afterwards",
	)
	for _ in 0 ..< 2 {
		print("    undo")
		success := undo(&h, state_ptrs)
		assert(success)
		print_state(state_ptrs)
	}

	// modify players and player positions at the same time:
	space_print("Now we move player 103 to ingame and set his position to {7,7}")
	print("    snapshot")
	snapshot(&h, StatePtrs{players = &players, positions = &positions})
	player_103 := pop(&players.waiting)
	assert(player_103 == 103)
	append(&players.ingame, player_103)
	positions[player_103] = {7, 7}
	print_state(state_ptrs)

	space_print(
		"Note the drop calls throwing away the 2 future states that were created by the last 2 undos\nNow set the world to Asia 5 times.",
	)
	for i in 0 ..< 5 {
		print("    snapshot")
		k = i
		snapshot(&h, StatePtrs{world = &world, k = &k})
		world = .Asia
		print_state(state_ptrs)
	}
}

// with MultiHistory, different fields of the same type are possible, (as opposed to DynamicHistory)
StatePtrs :: struct {
	players:   ^Players,
	positions: ^Positions,
	world:     ^World,
	i, k, j:   ^int,
}


IVec2 :: [2]int
PlayerId :: distinct u32
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


space_print :: proc(args: ..any) {
	print("\n");print(..args);print("\n")
}

print_state :: proc(ptrs: StatePtrs) {
	fmt.println(
		"    players: ",
		ptrs.players^,
		"positions: ",
		ptrs.positions^,
		"world: ",
		ptrs.world^,
		"i, j, k: ",
		ptrs.i^,
		ptrs.j^,
		ptrs.k^,
	)
}
