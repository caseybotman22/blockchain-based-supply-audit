;; supplier-registry
;; Smart contract to register suppliers and verify credentials in the supply chain audit system

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_SUPPLIER_NOT_FOUND (err u101))
(define-constant ERR_SUPPLIER_ALREADY_EXISTS (err u102))
(define-constant ERR_INVALID_STATUS (err u103))
(define-constant ERR_INVALID_SCORE (err u104))
(define-constant ERR_EMPTY_NAME (err u105))
(define-constant ERR_EMPTY_CATEGORY (err u106))
(define-constant ERR_INVALID_PRINCIPAL (err u107))

;; Status constants
(define-constant STATUS_PENDING u0)
(define-constant STATUS_VERIFIED u1)
(define-constant STATUS_SUSPENDED u2)
(define-constant STATUS_REJECTED u3)

;; Compliance level constants
(define-constant COMPLIANCE_BASIC u1)
(define-constant COMPLIANCE_STANDARD u2)
(define-constant COMPLIANCE_PREMIUM u3)
(define-constant COMPLIANCE_ENTERPRISE u4)

;; data maps and vars
;; Map to store supplier information
(define-map suppliers
  { supplier-id: uint }
  {
    owner: principal,
    name: (string-ascii 50),
    category: (string-ascii 30),
    registration-block: uint,
    last-update-block: uint,
    status: uint,
    compliance-score: uint,
    compliance-level: uint,
    certifications: (list 5 (string-ascii 20)),
    contact-info: (string-ascii 100),
    is-active: bool
  }
)

;; Map to track supplier addresses to IDs
(define-map supplier-addresses
  { owner: principal }
  { supplier-id: uint }
)

;; Map to store verification details
(define-map verification-details
  { supplier-id: uint }
  {
    verifier: principal,
    verification-date: uint,
    verification-notes: (string-ascii 200),
    documents-hash: (buff 32),
    expiry-block: uint
  }
)

;; Map to track authorized verifiers
(define-map authorized-verifiers
  { verifier: principal }
  { is-authorized: bool, authorization-date: uint }
)

;; Global counters and state
(define-data-var next-supplier-id uint u1)
(define-data-var total-suppliers uint u0)
(define-data-var total-verified-suppliers uint u0)
(define-data-var contract-paused bool false)

;; Events (using print for logging)
(define-private (emit-supplier-registered (supplier-id uint) (owner principal) (name (string-ascii 50)))
  (print {
    event: "supplier-registered",
    supplier-id: supplier-id,
    owner: owner,
    name: name,
    block-height: stacks-block-height
  })
)

(define-private (emit-supplier-verified (supplier-id uint) (verifier principal) (status uint))
  (print {
    event: "supplier-verified",
    supplier-id: supplier-id,
    verifier: verifier,
    status: status,
    block-height: stacks-block-height
  })
)

;; private functions
;; Validate supplier status
(define-private (is-valid-status (status uint))
  (or (is-eq status STATUS_PENDING)
      (or (is-eq status STATUS_VERIFIED)
          (or (is-eq status STATUS_SUSPENDED)
              (is-eq status STATUS_REJECTED))))
)

;; Validate compliance score (0-100)
(define-private (is-valid-compliance-score (score uint))
  (<= score u100)
)

;; Validate compliance level
(define-private (is-valid-compliance-level (level uint))
  (and (>= level COMPLIANCE_BASIC) (<= level COMPLIANCE_ENTERPRISE))
)

;; Calculate compliance level based on score
(define-private (calculate-compliance-level (score uint))
  (if (>= score u90)
    COMPLIANCE_ENTERPRISE
    (if (>= score u75)
      COMPLIANCE_PREMIUM
      (if (>= score u60)
        COMPLIANCE_STANDARD
        COMPLIANCE_BASIC)))
)

;; Check if caller is authorized verifier
(define-private (is-authorized-verifier (verifier principal))
  (default-to false (get is-authorized (map-get? authorized-verifiers { verifier: verifier })))
)

;; Validate string is not empty
(define-private (is-string-not-empty (str (string-ascii 50)))
  (> (len str) u0)
)

;; Check if contract is not paused
(define-private (is-contract-active)
  (not (var-get contract-paused))
)

;; public functions
;; Initialize contract with owner as first authorized verifier
(define-public (initialize)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set authorized-verifiers 
      { verifier: CONTRACT_OWNER } 
      { is-authorized: true, authorization-date: stacks-block-height }
    )
    (ok true)
  )
)

;; Register a new supplier
(define-public (register-supplier 
    (name (string-ascii 50))
    (category (string-ascii 30))
    (contact-info (string-ascii 100))
    (certifications (list 5 (string-ascii 20))))
  (let
    (
      (supplier-id (var-get next-supplier-id))
      (existing-supplier (map-get? supplier-addresses { owner: tx-sender }))
    )
    ;; Validate inputs and contract state
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-none existing-supplier) ERR_SUPPLIER_ALREADY_EXISTS)
    (asserts! (is-string-not-empty name) ERR_EMPTY_NAME)
    (asserts! (> (len category) u0) ERR_EMPTY_CATEGORY)
    
    ;; Create supplier record
    (map-set suppliers
      { supplier-id: supplier-id }
      {
        owner: tx-sender,
        name: name,
        category: category,
        registration-block: stacks-block-height,
        last-update-block: stacks-block-height,
        status: STATUS_PENDING,
        compliance-score: u0,
        compliance-level: COMPLIANCE_BASIC,
        certifications: certifications,
        contact-info: contact-info,
        is-active: true
      }
    )
    
    ;; Map address to supplier ID
    (map-set supplier-addresses
      { owner: tx-sender }
      { supplier-id: supplier-id }
    )
    
    ;; Update counters
    (var-set next-supplier-id (+ supplier-id u1))
    (var-set total-suppliers (+ (var-get total-suppliers) u1))
    
    ;; Emit event
    (emit-supplier-registered supplier-id tx-sender name)
    
    (ok supplier-id)
  )
)

;; Update supplier information (only by supplier owner)
(define-public (update-supplier-info
    (supplier-id uint)
    (name (string-ascii 50))
    (category (string-ascii 30))
    (contact-info (string-ascii 100))
    (certifications (list 5 (string-ascii 20))))
  (let
    (
      (supplier-data (unwrap! (map-get? suppliers { supplier-id: supplier-id }) ERR_SUPPLIER_NOT_FOUND))
    )
    ;; Validate authorization and inputs
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender (get owner supplier-data)) ERR_UNAUTHORIZED)
    (asserts! (is-string-not-empty name) ERR_EMPTY_NAME)
    (asserts! (> (len category) u0) ERR_EMPTY_CATEGORY)
    
    ;; Update supplier information
    (map-set suppliers
      { supplier-id: supplier-id }
      (merge supplier-data {
        name: name,
        category: category,
        contact-info: contact-info,
        certifications: certifications,
        last-update-block: stacks-block-height
      })
    )
    
    (ok true)
  )
)

;; Verify supplier (only by authorized verifiers)
(define-public (verify-supplier
    (supplier-id uint)
    (new-status uint)
    (compliance-score uint)
    (verification-notes (string-ascii 200))
    (documents-hash (buff 32))
    (expiry-blocks uint))
  (let
    (
      (supplier-data (unwrap! (map-get? suppliers { supplier-id: supplier-id }) ERR_SUPPLIER_NOT_FOUND))
      (current-verified-count (var-get total-verified-suppliers))
      (was-verified (is-eq (get status supplier-data) STATUS_VERIFIED))
      (will-be-verified (is-eq new-status STATUS_VERIFIED))
    )
    ;; Validate authorization and inputs
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-authorized-verifier tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-valid-status new-status) ERR_INVALID_STATUS)
    (asserts! (is-valid-compliance-score compliance-score) ERR_INVALID_SCORE)
    
    ;; Calculate compliance level
    (let ((compliance-level (calculate-compliance-level compliance-score)))
      ;; Update supplier verification status
      (map-set suppliers
        { supplier-id: supplier-id }
        (merge supplier-data {
          status: new-status,
          compliance-score: compliance-score,
          compliance-level: compliance-level,
          last-update-block: stacks-block-height
        })
      )
      
      ;; Store verification details
      (map-set verification-details
        { supplier-id: supplier-id }
        {
          verifier: tx-sender,
          verification-date: stacks-block-height,
          verification-notes: verification-notes,
          documents-hash: documents-hash,
          expiry-block: (+ stacks-block-height expiry-blocks)
        }
      )
      
      ;; Update verified suppliers counter
      (if (and (not was-verified) will-be-verified)
        (var-set total-verified-suppliers (+ current-verified-count u1))
        (if (and was-verified (not will-be-verified))
          (var-set total-verified-suppliers (- current-verified-count u1))
          true
        )
      )
      
      ;; Emit event
      (emit-supplier-verified supplier-id tx-sender new-status)
      
      (ok true)
    )
  )
)

;; Add authorized verifier (only contract owner)
(define-public (add-authorized-verifier (verifier principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq verifier tx-sender)) ERR_INVALID_PRINCIPAL)
    
    (map-set authorized-verifiers
      { verifier: verifier }
      { is-authorized: true, authorization-date: stacks-block-height }
    )
    
    (ok true)
  )
)

;; Remove authorized verifier (only contract owner)
(define-public (remove-authorized-verifier (verifier principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq verifier CONTRACT_OWNER)) ERR_INVALID_PRINCIPAL)
    
    (map-set authorized-verifiers
      { verifier: verifier }
      { is-authorized: false, authorization-date: stacks-block-height }
    )
    
    (ok true)
  )
)

;; Read-only functions
;; Get supplier information
(define-read-only (get-supplier (supplier-id uint))
  (map-get? suppliers { supplier-id: supplier-id })
)

;; Get supplier ID by address
(define-read-only (get-supplier-id (owner principal))
  (map-get? supplier-addresses { owner: owner })
)

;; Get verification details
(define-read-only (get-verification-details (supplier-id uint))
  (map-get? verification-details { supplier-id: supplier-id })
)

;; Check if verifier is authorized
(define-read-only (get-verifier-authorization (verifier principal))
  (map-get? authorized-verifiers { verifier: verifier })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  (ok {
    total-suppliers: (var-get total-suppliers),
    total-verified-suppliers: (var-get total-verified-suppliers),
    next-supplier-id: (var-get next-supplier-id),
    contract-paused: (var-get contract-paused)
  })
)

;; Check if supplier is verified and active
(define-read-only (is-supplier-verified (supplier-id uint))
  (match (map-get? suppliers { supplier-id: supplier-id })
    supplier-data (and (is-eq (get status supplier-data) STATUS_VERIFIED)
                      (get is-active supplier-data))
    false
  )
)

;; Get suppliers by status (helper for external queries)
(define-read-only (get-supplier-status (supplier-id uint))
  (match (map-get? suppliers { supplier-id: supplier-id })
    supplier-data (some (get status supplier-data))
    none
  )
)

