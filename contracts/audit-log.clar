;; audit-log
;; Smart contract to record and track supply chain audit results

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_AUDIT_NOT_FOUND (err u201))
(define-constant ERR_INVALID_AUDIT_TYPE (err u202))
(define-constant ERR_INVALID_SCORE (err u203))
(define-constant ERR_EMPTY_DESCRIPTION (err u204))
(define-constant ERR_INVALID_SUPPLIER_ID (err u205))
(define-constant ERR_DUPLICATE_AUDIT (err u206))
(define-constant ERR_AUDIT_EXPIRED (err u207))
(define-constant ERR_INVALID_BATCH_SIZE (err u208))

;; Audit type constants
(define-constant AUDIT_TYPE_COMPLIANCE u1)
(define-constant AUDIT_TYPE_QUALITY u2)
(define-constant AUDIT_TYPE_SECURITY u3)
(define-constant AUDIT_TYPE_ENVIRONMENTAL u4)
(define-constant AUDIT_TYPE_FINANCIAL u5)
(define-constant AUDIT_TYPE_OPERATIONAL u6)

;; Audit status constants
(define-constant AUDIT_STATUS_PENDING u0)
(define-constant AUDIT_STATUS_IN_PROGRESS u1)
(define-constant AUDIT_STATUS_COMPLETED u2)
(define-constant AUDIT_STATUS_FAILED u3)
(define-constant AUDIT_STATUS_CANCELLED u4)

;; Risk level constants
(define-constant RISK_LEVEL_LOW u1)
(define-constant RISK_LEVEL_MEDIUM u2)
(define-constant RISK_LEVEL_HIGH u3)
(define-constant RISK_LEVEL_CRITICAL u4)

;; data maps and vars
;; Map to store audit records
(define-map audit-records
  { audit-id: uint }
  {
    supplier-id: uint,
    auditor: principal,
    audit-type: uint,
    audit-status: uint,
    audit-score: uint,
    risk-level: uint,
    audit-date: uint,
    completion-date: (optional uint),
    description: (string-ascii 200),
    findings: (string-ascii 500),
    recommendations: (string-ascii 500),
    evidence-hash: (buff 32),
    expiry-date: uint,
    is-active: bool
  }
)

;; Map to track supplier audits (for quick lookup)
(define-map supplier-audits
  { supplier-id: uint, audit-type: uint, audit-date: uint }
  { audit-id: uint }
)

;; Map to store audit summary by supplier
(define-map supplier-audit-summary
  { supplier-id: uint }
  {
    total-audits: uint,
    completed-audits: uint,
    failed-audits: uint,
    average-score: uint,
    last-audit-date: uint,
    highest-risk-level: uint
  }
)

;; Map to track authorized auditors
(define-map authorized-auditors
  { auditor: principal }
  { 
    is-authorized: bool, 
    authorization-date: uint, 
    audit-types: (list 10 uint),
    total-audits-conducted: uint
  }
)

;; Map for batch audit operations
(define-map batch-audit-operations
  { batch-id: uint }
  {
    auditor: principal,
    creation-date: uint,
    total-audits: uint,
    completed-audits: uint,
    batch-status: uint,
    batch-description: (string-ascii 100)
  }
)

;; Global counters and state
(define-data-var next-audit-id uint u1)
(define-data-var next-batch-id uint u1)
(define-data-var total-audits uint u0)
(define-data-var total-completed-audits uint u0)
(define-data-var total-failed-audits uint u0)
(define-data-var contract-paused bool false)

;; Events (using print for logging)
(define-private (emit-audit-created (audit-id uint) (supplier-id uint) (auditor principal) (audit-type uint))
  (print {
    event: "audit-created",
    audit-id: audit-id,
    supplier-id: supplier-id,
    auditor: auditor,
    audit-type: audit-type,
    block-height: stacks-block-height
  })
)

(define-private (emit-audit-completed (audit-id uint) (audit-score uint) (risk-level uint))
  (print {
    event: "audit-completed",
    audit-id: audit-id,
    audit-score: audit-score,
    risk-level: risk-level,
    block-height: stacks-block-height
  })
)

(define-private (emit-batch-audit-created (batch-id uint) (auditor principal) (audit-count uint))
  (print {
    event: "batch-audit-created",
    batch-id: batch-id,
    auditor: auditor,
    total-audits: audit-count,
    block-height: stacks-block-height
  })
)

;; private functions
;; Validate audit type
(define-private (is-valid-audit-type (audit-type uint))
  (and (>= audit-type AUDIT_TYPE_COMPLIANCE) 
       (<= audit-type AUDIT_TYPE_OPERATIONAL))
)

;; Validate audit status
(define-private (is-valid-audit-status (status uint))
  (and (>= status AUDIT_STATUS_PENDING) 
       (<= status AUDIT_STATUS_CANCELLED))
)

;; Validate audit score (0-100)
(define-private (is-valid-audit-score (score uint))
  (<= score u100)
)

;; Validate risk level
(define-private (is-valid-risk-level (level uint))
  (and (>= level RISK_LEVEL_LOW) (<= level RISK_LEVEL_CRITICAL))
)

;; Calculate risk level based on audit score
(define-private (calculate-risk-level (score uint))
  (if (<= score u30)
    RISK_LEVEL_CRITICAL
    (if (<= score u50)
      RISK_LEVEL_HIGH
      (if (<= score u70)
        RISK_LEVEL_MEDIUM
        RISK_LEVEL_LOW)))
)

;; Check if caller is authorized auditor
(define-private (is-authorized-auditor (auditor principal))
  (default-to false (get is-authorized (map-get? authorized-auditors { auditor: auditor })))
)

;; Check if auditor is authorized for specific audit type
(define-private (is-auditor-authorized-for-type (auditor principal) (audit-type uint))
  (match (map-get? authorized-auditors { auditor: auditor })
    auditor-data (is-some (index-of (get audit-types auditor-data) audit-type))
    false
  )
)

;; Validate string is not empty
(define-private (is-string-not-empty (str (string-ascii 200)))
  (> (len str) u0)
)

;; Check if contract is not paused
(define-private (is-contract-active)
  (not (var-get contract-paused))
)

;; Update supplier audit summary
(define-private (update-supplier-summary (supplier-id uint) (audit-score uint) (risk-level uint) (is-completed bool) (is-failed bool))
  (let
    (
      (current-summary (default-to 
        { 
          total-audits: u0, 
          completed-audits: u0, 
          failed-audits: u0, 
          average-score: u0, 
          last-audit-date: u0, 
          highest-risk-level: u0 
        }
        (map-get? supplier-audit-summary { supplier-id: supplier-id })
      ))
      (new-total (+ (get total-audits current-summary) u1))
      (new-completed (if is-completed (+ (get completed-audits current-summary) u1) (get completed-audits current-summary)))
      (new-failed (if is-failed (+ (get failed-audits current-summary) u1) (get failed-audits current-summary)))
      (current-avg (get average-score current-summary))
      (current-total-for-avg (get completed-audits current-summary))
      (new-avg (if is-completed
                  (if (> current-total-for-avg u0)
                    (/ (+ (* current-avg current-total-for-avg) audit-score) new-completed)
                    audit-score)
                  current-avg))
      (new-highest-risk (if (> risk-level (get highest-risk-level current-summary)) risk-level (get highest-risk-level current-summary)))
    )
    (map-set supplier-audit-summary
      { supplier-id: supplier-id }
      {
        total-audits: new-total,
        completed-audits: new-completed,
        failed-audits: new-failed,
        average-score: new-avg,
        last-audit-date: stacks-block-height,
        highest-risk-level: new-highest-risk
      }
    )
  )
)

;; public functions
;; Initialize contract with owner as first authorized auditor
(define-public (initialize)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set authorized-auditors 
      { auditor: CONTRACT_OWNER } 
      { 
        is-authorized: true, 
        authorization-date: stacks-block-height,
        audit-types: (list AUDIT_TYPE_COMPLIANCE AUDIT_TYPE_QUALITY AUDIT_TYPE_SECURITY AUDIT_TYPE_ENVIRONMENTAL AUDIT_TYPE_FINANCIAL AUDIT_TYPE_OPERATIONAL),
        total-audits-conducted: u0
      }
    )
    (ok true)
  )
)

;; Create new audit record
(define-public (create-audit
    (supplier-id uint)
    (audit-type uint)
    (description (string-ascii 200))
    (expiry-blocks uint))
  (let
    (
      (audit-id (var-get next-audit-id))
      (duplicate-check (map-get? supplier-audits { supplier-id: supplier-id, audit-type: audit-type, audit-date: stacks-block-height }))
    )
    ;; Validate inputs and authorization
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-authorized-auditor tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-auditor-authorized-for-type tx-sender audit-type) ERR_UNAUTHORIZED)
    (asserts! (is-valid-audit-type audit-type) ERR_INVALID_AUDIT_TYPE)
    (asserts! (> supplier-id u0) ERR_INVALID_SUPPLIER_ID)
    (asserts! (is-string-not-empty description) ERR_EMPTY_DESCRIPTION)
    (asserts! (is-none duplicate-check) ERR_DUPLICATE_AUDIT)
    
    ;; Create audit record
    (map-set audit-records
      { audit-id: audit-id }
      {
        supplier-id: supplier-id,
        auditor: tx-sender,
        audit-type: audit-type,
        audit-status: AUDIT_STATUS_PENDING,
        audit-score: u0,
        risk-level: RISK_LEVEL_LOW,
        audit-date: stacks-block-height,
        completion-date: none,
        description: description,
        findings: "",
        recommendations: "",
        evidence-hash: 0x00000000000000000000000000000000,
        expiry-date: (+ stacks-block-height expiry-blocks),
        is-active: true
      }
    )
    
    ;; Map supplier audit for quick lookup
    (map-set supplier-audits
      { supplier-id: supplier-id, audit-type: audit-type, audit-date: stacks-block-height }
      { audit-id: audit-id }
    )
    
    ;; Update counters
    (var-set next-audit-id (+ audit-id u1))
    (var-set total-audits (+ (var-get total-audits) u1))
    
    ;; Update supplier summary
    (update-supplier-summary supplier-id u0 RISK_LEVEL_LOW false false)
    
    ;; Emit event
    (emit-audit-created audit-id supplier-id tx-sender audit-type)
    
    (ok audit-id)
  )
)

;; Complete audit with results
(define-public (complete-audit
    (audit-id uint)
    (audit-score uint)
    (findings (string-ascii 500))
    (recommendations (string-ascii 500))
    (evidence-hash (buff 32)))
  (let
    (
      (audit-data (unwrap! (map-get? audit-records { audit-id: audit-id }) ERR_AUDIT_NOT_FOUND))
      (risk-level (calculate-risk-level audit-score))
      (current-completed (var-get total-completed-audits))
    )
    ;; Validate authorization and inputs
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender (get auditor audit-data)) ERR_UNAUTHORIZED)
    (asserts! (or (is-eq (get audit-status audit-data) AUDIT_STATUS_PENDING)
                  (is-eq (get audit-status audit-data) AUDIT_STATUS_IN_PROGRESS)) ERR_UNAUTHORIZED)
    (asserts! (> (get expiry-date audit-data) stacks-block-height) ERR_AUDIT_EXPIRED)
    (asserts! (is-valid-audit-score audit-score) ERR_INVALID_SCORE)
    
    ;; Update audit record
    (map-set audit-records
      { audit-id: audit-id }
      (merge audit-data {
        audit-status: AUDIT_STATUS_COMPLETED,
        audit-score: audit-score,
        risk-level: risk-level,
        completion-date: (some stacks-block-height),
        findings: findings,
        recommendations: recommendations,
        evidence-hash: evidence-hash
      })
    )
    
    ;; Update global counters
    (var-set total-completed-audits (+ current-completed u1))
    
    ;; Update auditor statistics
    (match (map-get? authorized-auditors { auditor: tx-sender })
      auditor-data (map-set authorized-auditors
        { auditor: tx-sender }
        (merge auditor-data {
          total-audits-conducted: (+ (get total-audits-conducted auditor-data) u1)
        })
      )
      false
    )
    
    ;; Update supplier summary
    (update-supplier-summary (get supplier-id audit-data) audit-score risk-level true false)
    
    ;; Emit event
    (emit-audit-completed audit-id audit-score risk-level)
    
    (ok true)
  )
)

;; Mark audit as failed
(define-public (fail-audit
    (audit-id uint)
    (failure-reason (string-ascii 200)))
  (let
    (
      (audit-data (unwrap! (map-get? audit-records { audit-id: audit-id }) ERR_AUDIT_NOT_FOUND))
      (current-failed (var-get total-failed-audits))
    )
    ;; Validate authorization
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender (get auditor audit-data)) ERR_UNAUTHORIZED)
    (asserts! (or (is-eq (get audit-status audit-data) AUDIT_STATUS_PENDING)
                  (is-eq (get audit-status audit-data) AUDIT_STATUS_IN_PROGRESS)) ERR_UNAUTHORIZED)
    
    ;; Update audit record
    (map-set audit-records
      { audit-id: audit-id }
      (merge audit-data {
        audit-status: AUDIT_STATUS_FAILED,
        completion-date: (some stacks-block-height),
        findings: failure-reason
      })
    )
    
    ;; Update global counters
    (var-set total-failed-audits (+ current-failed u1))
    
    ;; Update supplier summary
    (update-supplier-summary (get supplier-id audit-data) u0 RISK_LEVEL_CRITICAL false true)
    
    (ok true)
  )
)

;; Add authorized auditor (only contract owner)
(define-public (add-authorized-auditor (auditor principal) (audit-types (list 10 uint)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    
    (map-set authorized-auditors
      { auditor: auditor }
      { 
        is-authorized: true, 
        authorization-date: stacks-block-height,
        audit-types: audit-types,
        total-audits-conducted: u0
      }
    )
    
    (ok true)
  )
)

;; Remove authorized auditor (only contract owner)
(define-public (remove-authorized-auditor (auditor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq auditor CONTRACT_OWNER)) ERR_UNAUTHORIZED)
    
    (map-set authorized-auditors
      { auditor: auditor }
      { 
        is-authorized: false, 
        authorization-date: stacks-block-height,
        audit-types: (list),
        total-audits-conducted: u0
      }
    )
    
    (ok true)
  )
)

;; Create batch audit operation
(define-public (create-batch-audit
    (supplier-ids (list 20 uint))
    (audit-type uint)
    (description (string-ascii 100))
    (expiry-blocks uint))
  (let
    (
      (batch-id (var-get next-batch-id))
      (supplier-count (len supplier-ids))
    )
    ;; Validate inputs
    (asserts! (is-contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-authorized-auditor tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-auditor-authorized-for-type tx-sender audit-type) ERR_UNAUTHORIZED)
    (asserts! (and (> supplier-count u0) (<= supplier-count u20)) ERR_INVALID_BATCH_SIZE)
    (asserts! (is-valid-audit-type audit-type) ERR_INVALID_AUDIT_TYPE)
    
    ;; Create batch operation record
    (map-set batch-audit-operations
      { batch-id: batch-id }
      {
        auditor: tx-sender,
        creation-date: stacks-block-height,
        total-audits: supplier-count,
        completed-audits: u0,
        batch-status: AUDIT_STATUS_PENDING,
        batch-description: description
      }
    )
    
    ;; Update counters
    (var-set next-batch-id (+ batch-id u1))
    
    ;; Emit event
    (emit-batch-audit-created batch-id tx-sender supplier-count)
    
    (ok batch-id)
  )
)

;; Read-only functions
;; Get audit record
(define-read-only (get-audit (audit-id uint))
  (map-get? audit-records { audit-id: audit-id })
)

;; Get supplier audit summary
(define-read-only (get-supplier-audit-summary (supplier-id uint))
  (map-get? supplier-audit-summary { supplier-id: supplier-id })
)

;; Get auditor authorization details
(define-read-only (get-auditor-authorization (auditor principal))
  (map-get? authorized-auditors { auditor: auditor })
)

;; Get batch audit operation details
(define-read-only (get-batch-audit (batch-id uint))
  (map-get? batch-audit-operations { batch-id: batch-id })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  (ok {
    total-audits: (var-get total-audits),
    total-completed-audits: (var-get total-completed-audits),
    total-failed-audits: (var-get total-failed-audits),
    next-audit-id: (var-get next-audit-id),
    next-batch-id: (var-get next-batch-id),
    contract-paused: (var-get contract-paused)
  })
)

;; Check if audit is active and not expired
(define-read-only (is-audit-active (audit-id uint))
  (match (map-get? audit-records { audit-id: audit-id })
    audit-data (and (get is-active audit-data)
                   (> (get expiry-date audit-data) stacks-block-height)
                   (not (is-eq (get audit-status audit-data) AUDIT_STATUS_COMPLETED))
                   (not (is-eq (get audit-status audit-data) AUDIT_STATUS_FAILED))
                   (not (is-eq (get audit-status audit-data) AUDIT_STATUS_CANCELLED)))
    false
  )
)

;; Get audits by supplier
(define-read-only (get-supplier-audit-id (supplier-id uint) (audit-type uint) (audit-date uint))
  (map-get? supplier-audits { supplier-id: supplier-id, audit-type: audit-type, audit-date: audit-date })
)

;; Calculate supplier compliance score (average of all completed audits)
(define-read-only (get-supplier-compliance-score (supplier-id uint))
  (match (map-get? supplier-audit-summary { supplier-id: supplier-id })
    summary-data (if (> (get completed-audits summary-data) u0)
                    (some (get average-score summary-data))
                    none)
    none
  )
)

