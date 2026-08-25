export type ErrorCode =
  | 'authentication_failed'
  | 'invalid_input'
  | 'not_found'
  | 'profile_required'
  | 'store_error'
  | 'store_invalid_data'
  | 'transaction_failed'
  | 'internal_error'

export class MorselError extends Error {
  readonly code: ErrorCode
  readonly publicMessage: string

  constructor(code: ErrorCode, publicMessage: string, cause?: unknown) {
    super(publicMessage, { cause })
    this.name = 'MorselError'
    this.code = code
    this.publicMessage = publicMessage
  }
}

export class RepositoryError extends MorselError {
  constructor(message: string, cause?: unknown) {
    super('store_error', message, cause)
    this.name = 'RepositoryError'
  }
}

export class InvalidStoredDataError extends MorselError {
  constructor(message: string, cause?: unknown) {
    super('store_invalid_data', message, cause)
    this.name = 'InvalidStoredDataError'
  }
}

export class TransactionError extends MorselError {
  constructor(message: string, cause?: unknown) {
    super('transaction_failed', message, cause)
    this.name = 'TransactionError'
  }
}

export function errorMessage(error: unknown): string {
  if (error instanceof MorselError) {
    return error.publicMessage
  }
  return 'unexpected failure'
}
