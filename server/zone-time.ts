// Zone-safe day math for the Morsel day contract (issue #121).
//
// Day-scoped tools bucket "days" in a user-chosen IANA timezone. All math
// here goes through Intl.DateTimeFormat — never through fixed
// `offset * 3600_000` shortcuts — so DST-shifting zones get real local
// midnights. A date label (YYYY-MM-DD) is a calendar entity; the instant a
// local day starts is derived per zone.

const formatterCache = new Map<string, Intl.DateTimeFormat>()

interface DateParts {
  year: number
  month: number
  day: number
  hour: number
  minute: number
  second: number
  millisecond: number
}

function formatterFor(timeZone: string): Intl.DateTimeFormat {
  let formatter = formatterCache.get(timeZone)
  if (formatter === undefined) {
    formatter = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      fractionalSecondDigits: 3,
    })
    formatterCache.set(timeZone, formatter)
  }
  return formatter
}

function partsAt(instantMs: number, timeZone: string): DateParts {
  const parts = formatterFor(timeZone).formatToParts(new Date(instantMs))
  const values = new Map<string, string>()
  for (const part of parts) {
    if (part.type !== 'literal') values.set(part.type, part.value)
  }
  const number = (type: string): number => {
    const raw = values.get(type)
    return raw === undefined ? 0 : Number(raw)
  }
  return {
    year: number('year'),
    month: number('month'),
    day: number('day'),
    hour: number('hour'),
    minute: number('minute'),
    second: number('second'),
    millisecond: number('fractionalSecond'),
  }
}

const pad = (value: number): string => String(value).padStart(2, '0')

/** Local calendar date (YYYY-MM-DD) of an instant in the zone. */
export function zonedDateLabel(instantMs: number, timeZone: string): string {
  const parts = partsAt(instantMs, timeZone)
  return `${String(parts.year)}-${pad(parts.month)}-${pad(parts.day)}`
}

/** The zone's UTC offset (wall clock minus instant) at an instant, in ms. */
function offsetMsAt(instantMs: number, timeZone: string): number {
  const parts = partsAt(instantMs, timeZone)
  const asUtc = Date.UTC(
    parts.year,
    parts.month - 1,
    parts.day,
    parts.hour,
    parts.minute,
    parts.second,
    parts.millisecond,
  )
  return asUtc - instantMs
}

/**
 * The UTC instant when the zone's local day `date` starts (local midnight).
 * Converges by wall-clock error correction: the offset is locally constant,
 * so at most a few iterations are needed even across a DST transition.
 */
export function zonedDayStartMs(date: string, timeZone: string): number {
  const [yearRaw = '', monthRaw = '', dayRaw = ''] = date.split('-')
  const year = Number(yearRaw)
  const month = Number(monthRaw)
  const day = Number(dayRaw)
  const wallTarget = Date.UTC(year, month - 1, day, 0, 0, 0, 0)
  let guess = wallTarget
  for (let iteration = 0; iteration < 4; iteration += 1) {
    guess += wallTarget - (guess + offsetMsAt(guess, timeZone))
  }
  return guess
}

/** ISO instant when the zone's local day `date` starts. */
export function zonedDayStartInstant(date: string, timeZone: string): string {
  return new Date(zonedDayStartMs(date, timeZone)).toISOString()
}

/** ISO instant when the zone's local day AFTER `date` starts. */
export function zonedNextDayStartInstant(date: string, timeZone: string): string {
  return new Date(zonedDayStartMs(addCalendarDays(date, 1), timeZone)).toISOString()
}

/**
 * Pure calendar arithmetic on a YYYY-MM-DD label (timezone-free; a calendar
 * day is a date entity, so adding days never needs zone math).
 */
export function addCalendarDays(date: string, amount: number): string {
  const [yearRaw = '', monthRaw = '', dayRaw = ''] = date.split('-')
  const year = Number(yearRaw)
  const month = Number(monthRaw)
  const day = Number(dayRaw)
  return new Date(Date.UTC(year, month - 1, day + amount)).toISOString().slice(0, 10)
}
