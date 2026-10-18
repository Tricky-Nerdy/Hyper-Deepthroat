extends RefCounted
## Restorable replacement stacks. Only slots managed here are transactional.

var _slots: Dictionary = {}


func define(slot: String, getter: Callable, setter: Callable) -> bool:
	if slot.is_empty() or _slots.has(slot) or not getter.is_valid() or not setter.is_valid():
		return false
	_slots[slot] = {"base": getter.call(), "setter": setter, "entries": []}
	return true


func replace(owner: String, slot: String, value) -> bool:
	if owner.is_empty() or not _slots.has(slot):
		return false
	var s: Dictionary = _slots[slot]
	s.entries = s.entries.filter(func(e): return e.owner != owner)
	s.entries.append({"owner": owner, "value": value})
	s.setter.call(value)
	return true


func release(owner: String) -> void:
	for s in _slots.values():
		var previous: int = s.entries.size()
		s.entries = s.entries.filter(func(e): return e.owner != owner)
		if s.entries.size() != previous:
			s.setter.call(s.base if s.entries.is_empty() else s.entries.back().value)


func clear() -> void:
	for s in _slots.values():
		s.setter.call(s.base)
	_slots.clear()
