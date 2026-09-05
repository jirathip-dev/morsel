import type { MealImageMimeType } from '../packages/schema/food-types.ts'

// Food-photo byte acquisition and validation shared by log_meal and
// attach_meal_image (issue #122). The server never transcodes: JPEG is the
// canonical interchange format (the native app re-encodes camera HEIC to JPEG
// client-side), and PNG/WebP are accepted because the food-images bucket and
// the app's FoodImageStore allow them. Every accepted payload is stored
// byte-exact under food-images/{user_id}/{meal_log_id}.jpg with its REAL
// content type, so the bytes a client sent are the bytes storage holds.

export const MEAL_IMAGE_BUCKET = 'food-images'
// Short-lived signed URLs minted per read (never persisted, never logged).
export const MEAL_IMAGE_SIGNED_URL_TTL_SECONDS = 15 * 60
// image_base64 decoded byte budget (~5 MB, issue #122).
export const MEAL_IMAGE_MAX_DECODED_BYTES = 5 * 1024 * 1024
// image_url fetch byte budget: the storage bucket's file_size_limit (0004).
export const MEAL_IMAGE_MAX_FETCH_BYTES = 10 * 1024 * 1024
export const MEAL_IMAGE_FETCH_TIMEOUT_MS = 5_000
export const MEAL_IMAGE_MAX_REDIRECTS = 3

/** Raised for every photo-level rejection; `message` is the public image_error. */
export class MealImageRejectedError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'MealImageRejectedError'
  }
}

export interface MealImageBytes {
  bytes: Uint8Array
  contentType: MealImageMimeType
}

/** The fetcher seam used by image_url support (injected for tests). */
export type MealImageFetcher = (input: string, init?: RequestInit) => Promise<Response>

function isMealImageMimeType(value: string): value is MealImageMimeType {
  return value === 'image/jpeg' || value === 'image/png' || value === 'image/webp'
}

function readMagic(bytes: Uint8Array, offset: number, expected: number[]): boolean {
  if (bytes.length < offset + expected.length) {
    return false
  }
  return expected.every((byte, index) => bytes[offset + index] === byte)
}

/** Sniffs the actual container from magic bytes (never trusts declared labels). */
export function detectMealImageMimeType(bytes: Uint8Array): MealImageMimeType | undefined {
  if (readMagic(bytes, 0, [0xFF, 0xD8, 0xFF])) {
    return 'image/jpeg'
  }
  if (readMagic(bytes, 0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png'
  }
  if (readMagic(bytes, 0, [0x52, 0x49, 0x46, 0x46]) && readMagic(bytes, 8, [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp'
  }
  return undefined
}

function decodeBase64Bytes(data: string): Uint8Array {
  // Linear validation (a quantified regex on a ~7 MB payload overflows the
  // JS regex engine): charset scan, padding only at the tail, then a strict
  // length check. The byte budget is applied on the ENCODED length first so
  // an oversized photo is rejected before any 5 MB decode work.
  const maximumEncodedLength = Math.ceil(MEAL_IMAGE_MAX_DECODED_BYTES / 3) * 4
  if (data.length > maximumEncodedLength) {
    throw new MealImageRejectedError('the photo is too large (5 MB limit)')
  }
  let paddingSeen = false
  let paddingCount = 0
  for (let index = 0; index < data.length; index += 1) {
    const code = data.charCodeAt(index)
    const isAlphabet = (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A) || (code >= 0x30 && code <= 0x39) || code === 0x2B || code === 0x2F
    if (code === 0x3D) {
      paddingSeen = true
      paddingCount += 1
      continue
    }
    if (paddingSeen || !isAlphabet) {
      throw new MealImageRejectedError('the photo bytes are not valid base64')
    }
  }
  if (paddingCount > 2 || data.length % 4 !== 0) {
    throw new MealImageRejectedError('the photo bytes are not valid base64')
  }
  let binary: string
  try {
    binary = atob(data)
  } catch {
    throw new MealImageRejectedError('the photo bytes are not valid base64')
  }
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  if (bytes.length > MEAL_IMAGE_MAX_DECODED_BYTES) {
    throw new MealImageRejectedError('the photo is too large (5 MB limit)')
  }
  return bytes
}

/**
 * Decodes and validates an image_base64 payload. Byte budget and magic-byte
 * sniffing run here so every rejection is a reported image_error and the meal
 * itself is still logged.
 */
export function decodeMealImageBase64(data: string, mimeType: MealImageMimeType): MealImageBytes {
  const bytes = decodeBase64Bytes(data)
  if (bytes.length > MEAL_IMAGE_MAX_DECODED_BYTES) {
    throw new MealImageRejectedError('the photo is too large (5 MB limit)')
  }
  const detected = detectMealImageMimeType(bytes)
  if (detected === undefined) {
    throw new MealImageRejectedError('the photo bytes are not a supported image (send JPEG, PNG, or WebP)')
  }
  if (detected !== mimeType) {
    throw new MealImageRejectedError('the photo bytes do not match the declared format')
  }
  return { bytes, contentType: mimeType }
}

/** True when `hostname` is an IP literal inside a private/loopback/link-local range. */
function isPrivateIpLiteral(hostname: string): boolean {
  const normalized = hostname.replace(/^\[|\]$/g, '').toLowerCase()
  if (normalized.includes(':')) {
    if (normalized === '::' || normalized === '::1') {
      return true
    }
    const firstGroup = normalized.split(':')[0] ?? ''
    return firstGroup === 'fe80' || firstGroup === 'fc' || firstGroup === 'fd' || firstGroup === 'fec0'
  }
  const octets = normalized.split('.').map((part) => Number(part))
  if (octets.length !== 4 || octets.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return false
  }
  const [first, second] = octets
  if (first === undefined || second === undefined) {
    return false
  }
  if (first === 10 || first === 127) {
    return true
  }
  if (first === 169 && second === 254) {
    return true
  }
  if (first === 172 && second >= 16 && second <= 31) {
    return true
  }
  if (first === 192 && second === 168) {
    return true
  }
  if (first === 0 || first === 100 || first === 255) {
    return true
  }
  return false
}

function validateFetchTarget(url: URL): void {
  if (url.protocol !== 'https:') {
    throw new MealImageRejectedError('the photo URL must use HTTPS')
  }
  if (isPrivateIpLiteral(url.hostname)) {
    throw new MealImageRejectedError('the photo URL points at a private address')
  }
}

function contentTypeOf(response: Response): string | undefined {
  const header = response.headers.get('content-type')
  if (header === null) {
    return undefined
  }
  return header.split(';')[0]?.trim().toLowerCase()
}

/**
 * Fetches one HTTPS photo URL (issue #122): bounded by a 5 s timeout, a
 * 10 MB byte budget, an image-only content-type allowlist, and a manual
 * redirect loop that refuses non-HTTPS or private-range hops (best effort for
 * literal IPs; DNS-rebinding defense is out of scope). The real container is
 * sniffed from the bytes and must match the declared content type.
 */
export async function fetchMealImageBytes(urlText: string, fetcher: MealImageFetcher): Promise<MealImageBytes> {
  let current: URL
  try {
    current = new URL(urlText)
  } catch {
    throw new MealImageRejectedError('the photo URL is not valid')
  }
  validateFetchTarget(current)

  for (let hops = 0; hops <= MEAL_IMAGE_MAX_REDIRECTS; hops += 1) {
    const controller = new AbortController()
    const timer = setTimeout(() => {
      controller.abort()
    }, MEAL_IMAGE_FETCH_TIMEOUT_MS)
    let response: Response
    try {
      response = await fetcher(current.toString(), {
        method: 'GET',
        redirect: 'manual',
        signal: controller.signal,
        headers: { accept: 'image/jpeg, image/png, image/webp' },
      })
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') {
        throw new MealImageRejectedError('fetching the photo URL timed out (5 s limit)')
      }
      throw new MealImageRejectedError('the photo could not be fetched from the provided URL')
    } finally {
      clearTimeout(timer)
    }

    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get('location')
      if (location === null) {
        throw new MealImageRejectedError('the photo URL redirected without a target')
      }
      let next: URL
      try {
        next = new URL(location, current)
      } catch {
        throw new MealImageRejectedError('the photo URL redirected to an invalid address')
      }
      validateFetchTarget(next)
      current = next
      continue
    }
    if (!response.ok) {
      throw new MealImageRejectedError('the photo could not be fetched from the provided URL')
    }

    const declared = contentTypeOf(response)
    if (declared === undefined || !isMealImageMimeType(declared)) {
      throw new MealImageRejectedError('the photo URL response was not a supported image (send JPEG, PNG, or WebP)')
    }
    const lengthHeader = response.headers.get('content-length')
    if (lengthHeader !== null && Number(lengthHeader) > MEAL_IMAGE_MAX_FETCH_BYTES) {
      throw new MealImageRejectedError('the photo from the URL is too large (10 MB limit)')
    }
    const bytes = new Uint8Array(await response.arrayBuffer())
    if (bytes.length > MEAL_IMAGE_MAX_FETCH_BYTES) {
      throw new MealImageRejectedError('the photo from the URL is too large (10 MB limit)')
    }
    const detected = detectMealImageMimeType(bytes)
    if (detected === undefined) {
      throw new MealImageRejectedError('the photo URL bytes are not a supported image (send JPEG, PNG, or WebP)')
    }
    if (detected !== declared) {
      throw new MealImageRejectedError('the photo URL bytes do not match their content type')
    }
    return { bytes, contentType: detected }
  }
  throw new MealImageRejectedError('the photo URL redirected too many times')
}
