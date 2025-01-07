# Undo/Redo history types for the Odin programming language

This package exposes two history types: MultiHistory and SingleHistory. SingleHistory can be used to undo/redo something by saving and restoring a state of a single type T. It uses a ring buffer to manage the saved states and takes care of dropping and cloning the state as needed per user-defined drop and clone functions.

MultiHistory is similar, but supports saving changes for a fixed set of different types, without storing the entire data of all types every time.
For example if you make a painting application, in which your state is this:

```odin
State :: struct {
    foreground_texture: Texture // big, expensive to clone,
    background_texture: BackgroundTexture // big, expensive to clone,
    selection: Aabb, // just some rectangle, a few bytes only
}
BackgroundTexture :: distinct Texture
```

Then you don't want to clone the entire texture and put it into the history every time the user selects a different rectangle. The MultiHistory saves only the parts of the state that you give to it. Some operations might change only the foreground texture, some might change the background texture and the selection at once.
When a user says, save values of types X, Y and Z as a snapshot it creates a grouped allocation for these types, putting them next to each other in memory managing their lifecycle together, e.g. when they get too old and should be dropped.

See example_multi/example.odin and run `odin run example_multi` to see how the MultiHistory works:

```odin
// define some structs and clone/drop functions for non copy types
Players :: struct {
	waiting: [dynamic]PlayerId,
	ingame:  [dynamic]PlayerId,
}
players_clone :: proc(this: Players) -> (res: Players) {
	print("clone players: ", this)
	res.ingame = slice.clone_to_dynamic(this.ingame[:])
	res.waiting = slice.clone_to_dynamic(this.waiting[:])
	return res
}
players_drop :: proc(this: ^Players) {
	print("drop players: ", this^)
	delete(this.ingame)
	delete(this.waiting)
}
World :: enum {
	Europe,
	Asia,
	America,
}

players: Players
world: World
i, j, k: int
StatePtrs :: struct {
	players: ^Players,
	world:   ^World,
	i, j:    ^int,
}
state_ptrs := StatePtrs{&players, &world, &i, &j}
// create new history saving the last 3 snapshotted states.
h := history.multi_history_create(StatePtrs, 3)
// add clone/drop functions for players and positions, the other types are simple copy types
set_functions(&h, "players", Players, players_clone, players_drop)

// only players are saved, not the other parts of the state:
snapshot(&h, StatePtrs{players = &players})
append(&players.waiting, player_id)

// only j and world are snapshotted:
snapshot(&h, StatePtrs{j = &j, world = &world})
j = 420
world = .Asia

// undo redo functions to get back to previous snapshots
undo(&h, state_ptrs)
redo(&h, state_ptrs)
```
