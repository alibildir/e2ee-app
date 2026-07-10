package api

// router.go — chi router setup + route registration.
//
// Public surface:
//
//	api.Handler()    — the full mux (router + middleware chain).
//	api.MountOn(mux) — mount /api/v1 + /healthz onto an existing
//	                   http.Handler (e.g. the http.ServeMux in
//	                   cmd/server/main.go after PR-8 wire-up).
//
// Middleware chain (outermost to innermost):
//
//	RequestID -> DeviceContext -> AccessLog -> CORS -> MaxBytes
//	  -> [on /api/*] APIVersion -> RateLimit -> handler
//
// /healthz sits OUTSIDE the API middleware stack so the load
// balancer doesn't need to send X-API-Version or a device id
// to hit the liveness probe.
//
// JWT-protected subtree (Sprint 5 PR-32, ADV-3):
//
//	RequestID -> DeviceContext -> AccessLog -> CORS -> MaxBytes
//	  -> APIVersion -> RateLimit -> IsAuthorized -> handler
//
// /api/v1/auth is NOT inside the IsAuthorized subtree (a login
// endpoint that requires a valid token is a chicken-and-egg
// problem). Everything else under /api/v1 that touches
// user-specific state IS behind IsAuthorized. The matrix and
// operator/lookup handlers stay open because they are public
// transparency / utility endpoints (BRD §7).

import (
	"net/http"

	"github.com/go-chi/chi/v5"
)

// Handler returns the fully-wired chi.Mux. Use this directly in
// tests or pass it to http.Server in main().
func (a *API) Handler() http.Handler {
	return a.buildRouter()
}

// MountOn attaches the API surface onto the given mux under
// the conventional paths:
//
//	/healthz          — liveness probe (no API middleware)
//	/api/v1/...       — full REST surface (API middleware stack)
//	/api/v1           — alias (so /api/v1 without trailing slash
//	                    returns 404 from chi rather than a 200
//	                    from the parent mux)
//
// PR-8 calls MountOn with the bare http.ServeMux from
// cmd/server/main.go so the chi router handles only the
// application paths and the parent can host additional
// (non-API) infrastructure if needed.
func (a *API) MountOn(mux *http.ServeMux) {
	h := a.Handler()
	mux.Handle("/healthz", h)
	mux.Handle("/api/v1/", h)
	mux.Handle("/api/v1", h)
}

// buildRouter constructs the chi.Mux from scratch on every
// call. Cheap (no caching needed — it's just struct setup) and
// keeps the constructor's behavior deterministic for tests.
func (a *API) buildRouter() http.Handler {
	r := chi.NewRouter()

	// Outer middleware — applies to every request that hits
	// the chi router. /healthz sits at the root so it gets
	// these too but skips the API-version + rate-limit checks.
	r.Use(RequestIDMiddleware())
	r.Use(DeviceContextMiddleware())
	r.Use(AccessLogMiddleware(a.cfg.Logger))
	r.Use(CORSMiddleware(a.cfg.CORS))
	r.Use(MaxBytesMiddleware(a.cfg.MaxBodyBytes))

	// /healthz — liveness probe. Sits OUTSIDE the /api/v1
	// subtree so the load balancer doesn't need X-API-Version.
	// Returns a minimal JSON body. PR-8 wire-up extends this
	// to also ping Postgres + Redis.
	r.Get("/healthz", func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok","service":"opene2ee-backend"}`))
	})

	// Root: catch-all for paths that aren't /healthz and aren't
	// under /api/v1/. We return 404 rather than the default
	// "404 page not found" text so clients get a parseable body.
	r.Get("/", func(w http.ResponseWriter, req *http.Request) {
		writeError(w, http.StatusNotFound, ErrorBody{
			Code:    CodeNotFound,
			Message: "Use /api/v1/sessions, /api/v1/matrix, /api/v1/operator/lookup, or /api/v1/users/{hash}.",
		})
	})

	// /api/v1 subtree: API-version + rate-limit then handlers.
	//
	// ADV-3 (Sprint 5 PR-32): the JWT-protected subtree is a
	// nested chi.Router so the IsAuthorized middleware applies
	// to the protected routes WITHOUT applying to /api/v1/auth
	// (login must be reachable without a bearer token). The
	// public subtree keeps the original open endpoints
	// (matrix transparency, operator lookup).
	r.Route("/api/v1", func(r chi.Router) {
		r.Use(APIVersionMiddleware(a.cfg.AcceptedAPIVersions...))
		r.Use(RateLimitMiddleware(a.cfg.RateLimit))

		// auth (login) — outside the JWT-protected subtree.
		// Rate-limit still applies (login is brute-force-prone);
		// IsAuthorized does NOT (login bootstraps the token).
		r.Post("/auth", a.handleLogin())

		// public subtree — no JWT required.
		r.Group(func(r chi.Router) {
			// matrix (transparency)
			r.Get("/matrix", a.handleMatrix())

			// operator lookup (utility — public BTK reverse IP + MNP)
			r.Get("/operator/lookup", a.handleOperatorLookup())
		})

		// JWT-protected subtree. IsAuthorized verifies the
		// bearer token on every request and stamps the verified
		// subject into the request context. Kong's JWT plugin
		// does the same check at the gateway, so by the time a
		// request reaches these handlers it has already passed
		// authentication — the middleware is defence-in-depth.
		r.Group(func(r chi.Router) {
			r.Use(a.IsAuthorized())

			// sessions
			r.Post("/sessions", a.handleCreateSession())
			r.Get("/sessions", a.handleListSessions())
			r.Get("/sessions/{id}", a.handleGetSession())
			r.Post("/sessions/{id}/telemetry", a.handlePostTelemetry())

			// users (KVKK delete)
			r.Delete("/users/{device_id_hash}", a.handleDeleteUser())

			// webrtc signalling (Sprint 3 PR-21a)
			r.Get("/webrtc/config", a.handleWebRTCConfig())
			// Sprint 11.0B — long-poll GETs for offer/answer. The
			// mobile session orchestrator calls these with a 30s
			// timeout; the backend holds the connection open
			// until either the peer posts the counterpart SDP
			// (returns 200 + JSON body) or the long-poll window
			// expires (returns 204 + empty body). S58 invariant.
			r.Get("/webrtc/offer", a.handleWebRTCOfferLongPoll())
			r.Get("/webrtc/answer", a.handleWebRTCAnswerLongPoll())
			r.Post("/webrtc/offer", a.handleWebRTCOffer())
			r.Post("/webrtc/answer", a.handleWebRTCAnswer())
			r.Post("/webrtc/ice", a.handleWebRTCICE())
		})
	})

	return r
}