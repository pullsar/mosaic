export interface RateLimitDecision {
  allowed: boolean;
  retryAfterSeconds?: number;
}

export interface RateLimiter {
  consume(key: string, cost?: number): Promise<RateLimitDecision>;
}

/**
 * Foundation implementation. Production limits are introduced per route when
 * traffic/abuse requirements are known; callers depend only on RateLimiter.
 */
export class AllowAllRateLimiter implements RateLimiter {
  async consume(_key: string, _cost = 1): Promise<RateLimitDecision> {
    return {allowed: true};
  }
}
