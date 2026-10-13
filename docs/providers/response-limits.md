# Community response limits

Community requests stream at most 1 MiB of response data before JSON decoding. The loader checks advertised lengths and counts actual chunks, including responses with missing or inaccurate Content-Length and error responses. An injected transport is also checked before its response is returned to the client.

Oversized replies become a sanitized network/unavailable error. URLs, response bodies and credentials are never included in that error. Cancellation before, during or after transport completion remains cancellation, so canceled delivery cannot be recorded as successful.

The loader retains an injected URLSession configuration, delegate queue and redirect/authentication policy. Portable tests exercise byte boundaries, cancellation and policy forwarding supported by FoundationNetworking. Apple optional-selector compilation and real delegate redirect, authentication and timeout behavior require Apple execution; Linux skips do not satisfy those gates.

The loader is applied to the Community, Open Food Facts and NIH DSLD transports. Their per-response caps are 1 MiB for Community, 4 MiB for Open Food Facts and 8 MiB for DSLD (`BoundedResponseLimits`). An oversized reply from either of the two newer providers becomes a sanitized transport failure with the reason "response exceeded the local size limit".
