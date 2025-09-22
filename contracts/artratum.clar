;; Enhanced Token Vesting Contract

;; Error constants
(define-constant err-not-found u1)
(define-constant err-unauthorized u2)
(define-constant err-grant-revoked u3)
(define-constant err-no-withdrawable u4)

;; Contract owner
(define-constant contract-owner tx-sender)

;; Grant storage (keeping the same structure)
(define-map grants uint { 
  recipient: principal, 
  total: uint, 
  start-height: uint, 
  cliff: uint, 
  duration: uint, 
  revoked: bool, 
  withdrawn: uint 
})

;; Create a new vesting grant (enhanced with access control)
(define-public (create-grant (id uint) (recipient principal) (total uint) (start uint) (cliff uint) (duration uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) (err err-unauthorized))
    (map-set grants id { 
      recipient: recipient, 
      total: total, 
      start-height: start, 
      cliff: cliff, 
      duration: duration, 
      revoked: false, 
      withdrawn: u0 
    })
    (ok true)))

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

;; Withdraw vested tokens
(define-public (withdraw (id uint))
  (match (map-get? grants id)
    grant
      (begin
        (asserts! (is-eq tx-sender (get recipient grant)) (err err-unauthorized))
        (asserts! (not (get revoked grant)) (err err-grant-revoked))
        (match (withdrawable id)
          amount
            (if (> amount u0)
              (begin
                (map-set grants id (merge grant { withdrawn: (+ (get withdrawn grant) amount) }))
                (ok amount))
              (err err-no-withdrawable))
          error (err error)))
    (err err-not-found)))

;; Revoke a grant (only contract owner)
(define-public (revoke-grant (id uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) (err err-unauthorized))
    (match (map-get? grants id)
      grant
        (begin
          (map-set grants id (merge grant { revoked: true }))
          (ok true))
      (err err-not-found))))

;; Get grant details (helper function)
(define-read-only (get-grant (id uint))
  (map-get? grants id))

;; Get grant status (helper function)
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
                revoked: (get revoked grant)
              })
            error (err error))
        error (err error))
    (err err-not-found)))