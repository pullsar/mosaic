import {Counter, Gauge, Histogram, Registry} from 'prom-client';

export interface RequestMetricLabels {
  method: string;
  route: string;
  status_class: string;
}

export interface ApiMetrics {
  registry: Registry;
  observeRequest(labels: RequestMetricLabels, durationSeconds: number): void;
}

export function createApiMetrics(releaseSha: string): ApiMetrics {
  const registry = new Registry();
  const requestCount = new Counter({
    name: 'mixli_http_requests_total',
    help: 'Completed Mixli API HTTP requests.',
    labelNames: ['method', 'route', 'status_class'],
    registers: [registry],
  });
  const requestDuration = new Histogram({
    name: 'mixli_http_request_duration_seconds',
    help: 'Mixli API HTTP request duration in seconds.',
    labelNames: ['method', 'route', 'status_class'],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    registers: [registry],
  });
  const releaseInfo = new Gauge({
    name: 'mixli_release_info',
    help: 'Active Mixli API release information.',
    labelNames: ['sha'],
    registers: [registry],
  });
  releaseInfo.set({sha: releaseSha}, 1);

  return {
    registry,
    observeRequest(labels, durationSeconds) {
      requestCount.inc(labels);
      requestDuration.observe(labels, durationSeconds);
    },
  };
}
