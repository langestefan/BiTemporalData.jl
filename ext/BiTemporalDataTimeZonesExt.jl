module BiTemporalDataTimeZonesExt

using TimeZones: ZonedDateTime, UTC
using Dates: DateTime
import BiTemporalData: _instant

# Store a zoned time as its UTC instant, so valid/transaction times given in
# different zones still order and compare correctly. `DateTime(z)` would keep the
# naive local wall-clock and silently drop the offset, so use the UTC conversion.
_instant(z::ZonedDateTime) = DateTime(z, UTC)

end # module
