```odin
State :: struct {
	players:   Players,   // struct { offline, ingame: [dynamic]PlayerId }
	positions: Positions, // map[PlayerId][2]int
	world:     enum {Asia, America, Europe},
}
s: State
h: history.MultiHistory = history.multi_history_create(10)
add_type(&h, Players, players_clone, players_drop)
add_type(&h, Positions, positions_clone, positions_drop)
add_type(&h, World)

snapshot(&h, s.players, s.positions)
append(&s.players, 101)
s.positions[101] = {0,2}

snapshot(&h, s.world)
s.world = .Asia

undo(&h, &s.players, &s.positions, &s.world)
undo(&h, &s.players, &s.positions, &s.world)

redo(&h, &s.players, &s.positions, &s.world)
```
