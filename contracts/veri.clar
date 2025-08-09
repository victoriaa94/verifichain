;; VerifiChain - Decentralized Identity Verification Platform
;; A comprehensive smart contract system for managing digital identity verification
;; Features: Multi-level verification, credential management, and decentralized trust network

(define-constant platform-admin tx-sender)

;; Error codes
(define-constant err-unauthorized-access (err u100))
(define-constant err-validator-exists (err u101))
(define-constant err-invalid-validator (err u102))
(define-constant err-identity-exists (err u103))
(define-constant err-identity-not-found (err u104))
(define-constant err-invalid-trust-tier (err u105))
(define-constant err-admin-only (err u106))
(define-constant err-invalid-credential-hash (err u107))
(define-constant err-expired-verification (err u108))
(define-constant err-insufficient-trust-level (err u109))

;; Trust tier constants
(define-constant tier-basic u1)
(define-constant tier-standard u2)
(define-constant tier-premium u3)
(define-constant tier-enterprise u4)

;; Verification validity period (blocks)
(define-constant verification-validity-period u144000) ;; ~100 days

;; Data structures
(define-map identity-validators 
  principal 
  { 
    active: bool, 
    registration-block: uint, 
    max-trust-tier: uint,
    total-verifications: uint 
  }
)

(define-map verified-identities 
  { identity-holder: principal } 
  { 
    is-verified: bool, 
    trust-tier: uint, 
    verification-timestamp: uint, 
    credential-hash: (buff 32),
    validator-address: principal,
    expiry-block: uint
  }
)

(define-map validator-reputation
  principal
  {
    success-count: uint,
    total-verifications: uint,
    reputation-score: uint
  }
)

;; Events for external monitoring
(define-map verification-events
  { event-id: uint }
  {
    event-type: (string-ascii 32),
    identity-holder: principal,
    validator: principal,
    block-height: uint
  }
)

(define-data-var next-event-id uint u1)

;; Read-only functions

;; Check validator status
(define-read-only (is-active-validator (validator-address principal))
  (default-to false (get active (map-get? identity-validators validator-address)))
)

;; Get validator details
(define-read-only (get-validator-info (validator-address principal))
  (map-get? identity-validators validator-address)
)

;; Check identity verification status
(define-read-only (is-identity-verified (identity-holder principal))
  (let ((identity-data (map-get? verified-identities { identity-holder: identity-holder })))
    (match identity-data
      verification-record (and 
                           (get is-verified verification-record)
                           (> (get expiry-block verification-record) block-height))
      false)))

;; Get identity verification details
(define-read-only (get-identity-verification (identity-holder principal))
  (map-get? verified-identities { identity-holder: identity-holder })
)

;; Get identity trust tier
(define-read-only (get-identity-trust-tier (identity-holder principal))
  (match (get-identity-verification identity-holder)
    verification-record (if (and 
                             (get is-verified verification-record)
                             (> (get expiry-block verification-record) block-height))
                           (get trust-tier verification-record)
                           u0)
    u0))

;; Get validator reputation
(define-read-only (get-validator-reputation (validator-address principal))
  (map-get? validator-reputation validator-address)
)

;; Calculate reputation score
(define-read-only (calculate-reputation-score (success-count uint) (total-verifications uint))
  (if (> total-verifications u0)
      (/ (* success-count u100) total-verifications)
      u0))

;; Helper functions

;; Validate trust tier
(define-private (is-valid-trust-tier (tier uint))
  (and (>= tier tier-basic) (<= tier tier-enterprise)))

;; Validate credential hash
(define-private (is-valid-credential-hash (hash (buff 32)))
  (not (is-eq hash 0x0000000000000000000000000000000000000000000000000000000000000000)))

;; Log verification event
(define-private (log-verification-event (event-type (string-ascii 32)) (identity-holder principal) (validator principal))
  (let ((event-id (var-get next-event-id)))
    (map-set verification-events 
             { event-id: event-id }
             {
               event-type: event-type,
               identity-holder: identity-holder,
               validator: validator,
               block-height: block-height
             })
    (var-set next-event-id (+ event-id u1))
    event-id))

;; Update validator reputation
(define-private (update-validator-reputation (validator-address principal) (successful bool))
  (let ((current-rep (default-to 
                       { success-count: u0, total-verifications: u0, reputation-score: u0 }
                       (map-get? validator-reputation validator-address))))
    (let ((new-total (+ (get total-verifications current-rep) u1))
          (new-success (if successful 
                          (+ (get success-count current-rep) u1)
                          (get success-count current-rep))))
      (map-set validator-reputation 
               validator-address
               {
                 success-count: new-success,
                 total-verifications: new-total,
                 reputation-score: (calculate-reputation-score new-success new-total)
               }))))

;; Public functions

;; Register new identity validator
(define-public (register-identity-validator (validator-address principal) (max-tier uint))
  (begin
    (asserts! (is-eq tx-sender platform-admin) err-admin-only)
    (asserts! (not (is-active-validator validator-address)) err-validator-exists)
    (asserts! (is-valid-trust-tier max-tier) err-invalid-trust-tier)
    
    (map-set identity-validators 
             validator-address
             { 
               active: true, 
               registration-block: block-height, 
               max-trust-tier: max-tier,
               total-verifications: u0
             })
    
    (log-verification-event "VALIDATOR_REGISTERED" validator-address tx-sender)
    (ok true)))

;; Deactivate identity validator
(define-public (deactivate-validator (validator-address principal))
  (begin
    (asserts! (is-eq tx-sender platform-admin) err-admin-only)
    (asserts! (is-active-validator validator-address) err-invalid-validator)
    
    (map-set identity-validators 
             validator-address
             (merge (unwrap-panic (map-get? identity-validators validator-address))
                    { active: false }))
    
    (log-verification-event "VALIDATOR_DEACTIVATED" validator-address tx-sender)
    (ok true)))

;; Verify identity with comprehensive validation
(define-public (verify-identity (identity-holder principal) (trust-tier uint) (credential-hash (buff 32)))
  (let ((validator-info (unwrap! (get-validator-info tx-sender) err-invalid-validator))
        (identity-key { identity-holder: identity-holder })
        (expiry-block (+ block-height verification-validity-period)))
    
    (asserts! (get active validator-info) err-unauthorized-access)
    (asserts! (is-valid-trust-tier trust-tier) err-invalid-trust-tier)
    (asserts! (<= trust-tier (get max-trust-tier validator-info)) err-insufficient-trust-level)
    (asserts! (is-valid-credential-hash credential-hash) err-invalid-credential-hash)
    
    ;; Update validator statistics
    (map-set identity-validators 
             tx-sender
             (merge validator-info { total-verifications: (+ (get total-verifications validator-info) u1) }))
    
    ;; Create verification record
    (map-set verified-identities 
             identity-key
             { 
               is-verified: true, 
               trust-tier: trust-tier, 
               verification-timestamp: block-height, 
               credential-hash: credential-hash,
               validator-address: tx-sender,
               expiry-block: expiry-block
             })
    
    ;; Update reputation
    (update-validator-reputation tx-sender true)
    
    ;; Log event
    (log-verification-event "IDENTITY_VERIFIED" identity-holder tx-sender)
    (ok true)))

;; Revoke identity verification
(define-public (revoke-identity-verification (identity-holder principal))
  (let ((current-verification (unwrap! (get-identity-verification identity-holder) err-identity-not-found))
        (identity-key { identity-holder: identity-holder }))
    
    (asserts! (or 
               (is-eq tx-sender (get validator-address current-verification))
               (is-eq tx-sender platform-admin)
               (is-eq tx-sender identity-holder)) 
              err-unauthorized-access)
    
    (map-set verified-identities 
             identity-key
             (merge current-verification 
                    { 
                      is-verified: false,
                      trust-tier: u0,
                      expiry-block: block-height
                    }))
    
    (log-verification-event "VERIFICATION_REVOKED" identity-holder tx-sender)
    (ok true)))

;; Self-revoke verification
(define-public (self-revoke-verification)
  (revoke-identity-verification tx-sender))

;; Update trust tier for existing verification
(define-public (update-identity-trust-tier (identity-holder principal) (new-tier uint))
  (let ((current-verification (unwrap! (get-identity-verification identity-holder) err-identity-not-found))
        (validator-info (unwrap! (get-validator-info tx-sender) err-invalid-validator))
        (identity-key { identity-holder: identity-holder }))
    
    (asserts! (get active validator-info) err-unauthorized-access)
    (asserts! (is-valid-trust-tier new-tier) err-invalid-trust-tier)
    (asserts! (<= new-tier (get max-trust-tier validator-info)) err-insufficient-trust-level)
    (asserts! (> (get expiry-block current-verification) block-height) err-expired-verification)
    
    (map-set verified-identities 
             identity-key
             (merge current-verification 
                    { 
                      trust-tier: new-tier,
                      verification-timestamp: block-height,
                      validator-address: tx-sender
                    }))
    
    (log-verification-event "TIER_UPDATED" identity-holder tx-sender)
    (ok true)))

;; Renew verification before expiry
(define-public (renew-identity-verification (identity-holder principal) (new-credential-hash (buff 32)))
  (let ((current-verification (unwrap! (get-identity-verification identity-holder) err-identity-not-found))
        (validator-info (unwrap! (get-validator-info tx-sender) err-invalid-validator))
        (identity-key { identity-holder: identity-holder })
        (new-expiry (+ block-height verification-validity-period)))
    
    (asserts! (get active validator-info) err-unauthorized-access)
    (asserts! (is-valid-credential-hash new-credential-hash) err-invalid-credential-hash)
    (asserts! (> (get expiry-block current-verification) block-height) err-expired-verification)
    
    (map-set verified-identities 
             identity-key
             (merge current-verification 
                    { 
                      verification-timestamp: block-height,
                      credential-hash: new-credential-hash,
                      validator-address: tx-sender,
                      expiry-block: new-expiry
                    }))
    
    (log-verification-event "VERIFICATION_RENEWED" identity-holder tx-sender)
    (ok true)))

;; Batch verification for multiple identities
(define-public (batch-verify-identities (identities (list 10 { holder: principal, tier: uint, hash: (buff 32) })))
  (fold batch-verify-helper identities (ok u0)))

(define-private (batch-verify-helper (identity-data { holder: principal, tier: uint, hash: (buff 32) }) (previous-result (response uint uint)))
  (match previous-result
    success-count (match (verify-identity (get holder identity-data) (get tier identity-data) (get hash identity-data))
                    success (ok (+ success-count u1))
                    error (err error))
    error (err error)))