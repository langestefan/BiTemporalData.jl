# The four primitives every backend implements.

"`get_records(s, key)`: all records for `key` in append order; empty if unknown."
function get_records end

"`put_record!(s, key, record)`: append `record` (`id = nothing`); return it with `id` assigned."
function put_record! end

"`close_tx!(s, id, ts)`: set the record's `tx_to` to `ts`. Idempotent."
function close_tx! end

"`entities(s)`: all keys the store knows about."
function entities end
