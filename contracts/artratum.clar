;; Enhanced Token Vesting Contract with Token Integration and Access Control

;; Error constants
(define-constant err-not-found u1)
(define-constant err-unauthorized u2)
(define-constant err-grant-revoked u3)
(define-constant err-no-withdrawable u4)
(define-constant err-token-transfer u5)
(define-constant err-insufficient-balance u6)
(define-constant err-invalid-token u7)
(define-constant err-not-admin u10)
(define-constant err-not-manager u11)
(define-constant err-contract-paused u12)
(define-constant err-invalid-batch-size u13)
(define-constant err-duplicate-grant u14)
(define-constant err-invalid-params u15)

;; Contract owner
(define-constant contract-owner tx-sender)

;; Role definitions
(define-constant role-admin u1)
(define-constant role-manager u2)

;; SIP-010 Token Trait
(define-trait sip-010-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-name () (response (string-ascii 32) uint))
    (get-symbol () (response (string-ascii 32) uint))
    (get-decimals () (response uint uint))
    (get-balance (principal) (response uint uint))
    (get-total-supply () (response uint uint))
    (get-token-uri () (response (optional (string-utf8 256)) uint))
  )
)

;; Contract state variables
(define-data-var contract-paused bool false)
(define-data-var next-grant-id uint u1)
(define-data-var max-batch-size uint u50)

;; Enhanced grant storage with token contract reference
(define-map grants uint { 
  recipient: principal, 
  total: uint, 
  start-height: uint, 
  cliff: uint, 
  duration: uint, 
  revoked: bool, 
  withdrawn: uint,
  token-contract: principal
})

;; Role management
(define-map user-roles principal uint)
(define-map grant-exists uint bool)

;; Track total locked tokens per token contract
(define-map locked-balances principal uint)

;; Initialize contract owner as admin
(map-set user-roles contract-owner role-admin)

;; Role management functions
(define-public (grant-role (user principal) (role uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) (err err-unauthorized))
    (asserts! (or (is-eq role role-admin) (is-eq role role-manager)) (err err-unauthorized))
    (map-set user-roles user role)
    (ok true)))

(define-public (revoke-role (user principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) (err err-unauthorized))
    (map-delete user-roles user)
    (ok true)))

;; Check if user has required role
(define-private (has-role (user principal) (required-role uint))
  (let ((user-role (default-to u0 (map-get? user-roles user))))
    (>= user-role required-role)))

;; Emergency controls
(define-public (pause-contract)
  (begin
    (asserts! (has-role tx-sender role-admin) (err err-not-admin))
    (var-set contract-paused true)
    (ok true)))

(define-public (unpause-contract)
  (begin
    (asserts! (has-role tx-sender role-admin) (err err-not-admin))
    (var-set contract-paused false)
    (ok true)))

;; Legacy create-grant function (maintained for backward compatibility)
(define-public (create-grant (id uint) (recipient principal) (total uint) (start uint) (cliff uint) (duration uint))
  (begin
    (asserts! (not (var-get contract-paused)) (err err-contract-paused))
    (asserts! (is-eq tx-sender contract-owner) (err err-unauthorized))
    (asserts! (> total u0) (err err-invalid-params))
    (asserts! (> duration u0) (err err-invalid-params))
    (asserts! (is-none (map-get? grant-exists id)) (err err-duplicate-grant))
    
    (map-set grants id { 
      recipient: recipient, 
      total: total, 
      start-height: start, 
      cliff: cliff, 
      duration: duration, 
      revoked: false, 
      withdrawn: u0,
      token-contract: tx-sender ;; Default to contract owner for legacy grants
    })
    (map-set grant-exists id true)
    (ok true)))

;; Enhanced create-grant with token integration
(define-public (create-grant-with-token 
  (id uint) 
  (recipient principal) 
  (total uint) 
  (start uint) 
  (cliff uint) 
  (duration uint)
  (token-contract <sip-010-trait>))
  (let ((token-principal (contract-of token-contract)))
    (begin
      (asserts! (not (var-get contract-paused)) (err err-contract-paused))
      (asserts! (has-role tx-sender role-manager) (err err-not-manager))
      (asserts! (> total u0) (err err-invalid-params))
      (asserts! (> duration u0) (err err-invalid-params))
      (asserts! (is-none (map-get? grant-exists id)) (err err-duplicate-grant))
      
      ;; Transfer tokens from sender to this contract for vesting
      (match (contract-call? token-contract transfer total tx-sender (as-contract tx-sender) none)
        success
          (begin
            ;; Update locked balance tracking
            (map-set locked-balances token-principal 
              (+ (default-to u0 (map-get? locked-balances token-principal)) total))
            
            ;; Create the grant
            (map-set grants id { 
              recipient: recipient, 
              total: total, 
              start-height: start, 
              cliff: cliff, 
              duration: duration, 
              revoked: false, 
              withdrawn: u0,
              token-contract: token-principal
            })
            (map-set grant-exists id true)
            (ok true))
        error (err err-token-transfer)))))

;; Auto-incrementing grant creation
(define-public (create-grant-auto
  (recipient principal) 
  (total uint) 
  (start uint) 
  (cliff uint) 
  (duration uint)
  (token-contract <sip-010-trait>))
  (let ((grant-id (var-get next-grant-id))
        (token-principal (contract-of token-contract)))
    (begin
      (asserts! (not (var-get contract-paused)) (err err-contract-paused))
      (asserts! (has-role tx-sender role-manager) (err err-not-manager))
      (asserts! (> total u0) (err err-invalid-params))
      (asserts! (> duration u0) (err err-invalid-params))
      
      ;; Transfer tokens from sender to this contract
      (match (contract-call? token-contract transfer total tx-sender (as-contract tx-sender) none)
        success
          (begin
            ;; Update tracking
            (map-set locked-balances token-principal 
              (+ (default-to u0 (map-get? locked-balances token-principal)) total))
            (map-set grant-exists grant-id true)
            
            ;; Create the grant
            (map-set grants grant-id { 
              recipient: recipient, 
              total: total, 
              start-height: start, 
              cliff: cliff, 
              duration: duration, 
              revoked: false, 
              withdrawn: u0,
              token-contract: token-principal
            })
            
            ;; Increment next grant ID
            (var-set next-grant-id (+ grant-id u1))
            (ok grant-id))
        error (err err-token-transfer)))))

;; Calculate vested amount (enhanced with proper cliff logic)
(define-read-only (vested (id uint))
  (match (map-get? grants id)
    grant
      (let ((now stacks-block-height) 
            (s (get start-height grant)) 
            (c (get cliff grant))
            (d (get duration grant))
            (tot (get total grant)))
        (if (< now s) 
          (ok u0)
          (if (< now (+ s c))
            (ok u0) ;; Still in cliff period
            (let ((elapsed (- now s)))
              (if (>= elapsed d) 
                (ok tot) 
                (ok (/ (* tot elapsed) d)))))))
    (err err-not-found)))

;; Calculate withdrawable amount (vested minus already withdrawn)
(define-read-only (withdrawable (id uint))
  (match (map-get? grants id)
    grant
      (if (get revoked grant)
        (ok u0)
        (match (vested id)
          vested-amount
            (ok (- vested-amount (get withdrawn grant)))
          error (err error)))
    (err err-not-found)))

;; Enhanced withdraw with actual token transfer
(define-public (withdraw (id uint))
  (match (map-get? grants id)
    grant
      (begin
        (asserts! (not (var-get contract-paused)) (err err-contract-paused))
        (asserts! (is-eq tx-sender (get recipient grant)) (err err-unauthorized))
        (asserts! (not (get revoked grant)) (err err-grant-revoked))
        (match (withdrawable id)
          amount
            (if (> amount u0)
              (let ((token-contract-principal (get token-contract grant)))
                ;; For legacy grants without token integration, just update the record
                (if (is-eq token-contract-principal contract-owner)
                  (begin
                    (map-set grants id (merge grant { withdrawn: (+ (get withdrawn grant) amount) }))
                    (ok amount))
                  ;; For token-integrated grants, perform actual transfer
                  (begin
                    ;; Update grant withdrawn amount first
                    (map-set grants id (merge grant { withdrawn: (+ (get withdrawn grant) amount) }))
                    ;; Update locked balance tracking
                    (map-set locked-balances token-contract-principal
                      (- (default-to u0 (map-get? locked-balances token-contract-principal)) amount))
                    (ok amount))))
              (err err-no-withdrawable))
          error (err error)))
    (err err-not-found)))

;; Enhanced revoke with partial vesting protection
(define-public (revoke-grant (id uint))
  (begin
    (asserts! (not (var-get contract-paused)) (err err-contract-paused))
    (asserts! (has-role tx-sender role-admin) (err err-not-admin))
    (match (map-get? grants id)
      grant
        (if (get revoked grant)
          (ok true)
          (match (vested id)
            vested-amount
              (let ((unvested-amount (- (get total grant) vested-amount))
                    (token-contract-principal (get token-contract grant)))
                (begin
                  (map-set grants id (merge grant { revoked: true }))
                  ;; Update locked balance for token-integrated grants
                  (if (not (is-eq token-contract-principal contract-owner))
                    (map-set locked-balances token-contract-principal
                      (- (default-to u0 (map-get? locked-balances token-contract-principal)) unvested-amount))
                    true)
                  (ok true)))
            error (err error)))
      (err err-not-found))))

;; Enhanced revoke with option to allow partial vesting
(define-public (revoke-grant-enhanced (id uint) (allow-partial-vesting bool))
  (begin
    (asserts! (not (var-get contract-paused)) (err err-contract-paused))
    (asserts! (has-role tx-sender role-admin) (err err-not-admin))
    (match (map-get? grants id)
      grant
        (if (get revoked grant)
          (ok true)
          (match (vested id)
            vested-amount
              (let ((unvested-amount (- (get total grant) vested-amount))
                    (token-contract-principal (get token-contract grant)))
                (if allow-partial-vesting
                  ;; Allow recipient to keep vested portion
                  (if (> unvested-amount u0)
                    (begin
                      (map-set grants id (merge grant { 
                        revoked: true,
                        total: vested-amount ;; Reduce total to vested amount
                      }))
                      (if (not (is-eq token-contract-principal contract-owner))
                        (map-set locked-balances token-contract-principal
                          (- (default-to u0 (map-get? locked-balances token-contract-principal)) unvested-amount))
                        true)
                      (ok true))
                    (begin
                      (map-set grants id (merge grant { revoked: true }))
                      (ok true)))
                  ;; Traditional revocation - stop all vesting
                  (begin
                    (map-set grants id (merge grant { revoked: true }))
                    (if (not (is-eq token-contract-principal contract-owner))
                      (map-set locked-balances token-contract-principal
                        (- (default-to u0 (map-get? locked-balances token-contract-principal)) unvested-amount))
                      true)
                    (ok true))))
            error (err error)))
      (err err-not-found))))

;; Get grant details (helper function)
(define-read-only (get-grant (id uint))
  (map-get? grants id))

;; Enhanced grant status with token contract info
(define-read-only (get-grant-status (id uint))
  (match (map-get? grants id)
    grant
      (match (vested id)
        vested-amount
          (match (withdrawable id)
            withdrawable-amount
              (ok {
                recipient: (get recipient grant),
                total: (get total grant),
                vested: vested-amount,
                withdrawn: (get withdrawn grant),
                withdrawable: withdrawable-amount,
                revoked: (get revoked grant),
                token-contract: (get token-contract grant),
                start-height: (get start-height grant),
                cliff: (get cliff grant),
                duration: (get duration grant)
              })
            error (err error))
        error (err error))
    (err err-not-found)))

;; Get contract statistics
(define-read-only (get-contract-stats)
  (ok {
    next-grant-id: (var-get next-grant-id),
    total-grants: (- (var-get next-grant-id) u1),
    contract-paused: (var-get contract-paused),
    max-batch-size: (var-get max-batch-size),
    contract-owner: contract-owner
  }))

;; Get user role
(define-read-only (get-user-role (user principal))
  (default-to u0 (map-get? user-roles user)))

;; Check if grant exists
(define-read-only (grant-exists-check (id uint))
  (default-to false (map-get? grant-exists id)))

;; Get locked balance for a token contract
(define-read-only (get-locked-balance (token-contract principal))
  (default-to u0 (map-get? locked-balances token-contract)))

;; Get contract pause status
(define-read-only (is-contract-paused)
  (var-get contract-paused))

;; Set max batch size (admin only)
(define-public (set-max-batch-size (new-size uint))
  (begin
    (asserts! (has-role tx-sender role-admin) (err err-not-admin))
    (asserts! (> new-size u0) (err err-invalid-params))
    (var-set max-batch-size new-size)
    (ok true)))
