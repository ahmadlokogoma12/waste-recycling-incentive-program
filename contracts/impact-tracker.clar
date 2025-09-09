;; Impact Tracker Smart Contract
;; Tracks recycling activities and calculates environmental impact metrics

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-INPUT (err u103))
(define-constant ERR-INSUFFICIENT-AMOUNT (err u104))
(define-constant ERR-CENTER-NOT-VERIFIED (err u105))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-WEIGHT u1) ;; Minimum weight in grams
(define-constant MAX-WEIGHT u100000) ;; Maximum weight in grams (100kg)

;; Material type constants
(define-constant MATERIAL-PAPER u1)
(define-constant MATERIAL-PLASTIC u2)
(define-constant MATERIAL-METAL u3)
(define-constant MATERIAL-GLASS u4)
(define-constant MATERIAL-ELECTRONICS u5)
(define-constant MATERIAL-ORGANIC u6)

;; Data variables
(define-data-var activity-counter uint u0)
(define-data-var total-co2-saved uint u0)
(define-data-var total-energy-saved uint u0)
(define-data-var contract-active bool true)

;; Data maps
(define-map recycling-activities
  { activity-id: uint }
  {
    user: principal,
    material-type: uint,
    weight-grams: uint,
    recycling-center: principal,
    timestamp: uint,
    location: (string-ascii 100),
    co2-impact: uint,
    energy-impact: uint,
    impact-score: uint,
    verified: bool
  }
)

(define-map user-impact-totals
  { user: principal }
  {
    total-activities: uint,
    total-weight: uint,
    total-co2-saved: uint,
    total-energy-saved: uint,
    total-impact-score: uint,
    last-activity: uint
  }
)

(define-map recycling-centers
  { center: principal }
  {
    name: (string-ascii 100),
    location: (string-ascii 200),
    verified: bool,
    registration-date: uint,
    total-activities: uint,
    operator: principal
  }
)

(define-map material-impact-rates
  { material-type: uint }
  {
    co2-per-gram: uint, ;; CO2 saved per gram in mg
    energy-per-gram: uint, ;; Energy saved per gram in mJ
    base-points: uint ;; Base impact points per gram
  }
)

(define-map daily-user-activities
  { user: principal, day: uint }
  { activity-count: uint, total-weight: uint }
)

(define-map material-statistics
  { material-type: uint }
  {
    total-weight: uint,
    total-activities: uint,
    total-impact: uint,
    average-weight: uint
  }
)

(define-map location-statistics
  { location: (string-ascii 100) }
  {
    total-activities: uint,
    total-impact: uint,
    active-users: uint
  }
)

;; Initialize material impact rates
(map-set material-impact-rates { material-type: MATERIAL-PAPER }
  { co2-per-gram: u3500, energy-per-gram: u2000, base-points: u10 })
(map-set material-impact-rates { material-type: MATERIAL-PLASTIC }
  { co2-per-gram: u6000, energy-per-gram: u4000, base-points: u25 })
(map-set material-impact-rates { material-type: MATERIAL-METAL }
  { co2-per-gram: u15000, energy-per-gram: u10000, base-points: u50 })
(map-set material-impact-rates { material-type: MATERIAL-GLASS }
  { co2-per-gram: u2000, energy-per-gram: u1500, base-points: u8 })
(map-set material-impact-rates { material-type: MATERIAL-ELECTRONICS }
  { co2-per-gram: u25000, energy-per-gram: u20000, base-points: u100 })
(map-set material-impact-rates { material-type: MATERIAL-ORGANIC }
  { co2-per-gram: u1000, energy-per-gram: u500, base-points: u5 })

;; Public functions

;; Register a new recycling center
(define-public (register-recycling-center 
  (name (string-ascii 100))
  (location (string-ascii 200))
)
  (let
    (
      (center tx-sender)
    )
    (asserts! (var-get contract-active) ERR-UNAUTHORIZED)
    (asserts! (> (len name) u0) ERR-INVALID-INPUT)
    (asserts! (> (len location) u0) ERR-INVALID-INPUT)
    (asserts! (is-none (map-get? recycling-centers { center: center })) ERR-ALREADY-EXISTS)
    
    (map-set recycling-centers
      { center: center }
      {
        name: name,
        location: location,
        verified: false,
        registration-date: block-height,
        total-activities: u0,
        operator: center
      }
    )
    (ok center)
  )
)

;; Verify a recycling center (admin only)
(define-public (verify-recycling-center (center principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? recycling-centers { center: center })) ERR-NOT-FOUND)
    
    (map-set recycling-centers
      { center: center }
      (merge 
        (unwrap-panic (map-get? recycling-centers { center: center }))
        { verified: true }
      )
    )
    (ok true)
  )
)

;; Record a recycling activity
(define-public (record-recycling-activity
  (material-type uint)
  (weight-grams uint)
  (recycling-center principal)
  (location (string-ascii 100))
)
  (let
    (
      (new-id (+ (var-get activity-counter) u1))
      (user tx-sender)
      (day (/ block-height u144)) ;; Approximate blocks per day
      (center-info (unwrap! (map-get? recycling-centers { center: recycling-center }) ERR-NOT-FOUND))
      (material-rates (unwrap! (map-get? material-impact-rates { material-type: material-type }) ERR-INVALID-INPUT))
    )
    (asserts! (var-get contract-active) ERR-UNAUTHORIZED)
    (asserts! (get verified center-info) ERR-CENTER-NOT-VERIFIED)
    (asserts! (and (>= weight-grams MIN-WEIGHT) (<= weight-grams MAX-WEIGHT)) ERR-INVALID-INPUT)
    (asserts! (<= material-type u6) ERR-INVALID-INPUT)
    
    ;; Calculate environmental impact
    (let
      (
        (co2-impact (* weight-grams (get co2-per-gram material-rates)))
        (energy-impact (* weight-grams (get energy-per-gram material-rates)))
        (base-score (* weight-grams (get base-points material-rates)))
        (impact-score (calculate-bonus-score base-score user day))
      )
      
      ;; Record the activity
      (map-set recycling-activities
        { activity-id: new-id }
        {
          user: user,
          material-type: material-type,
          weight-grams: weight-grams,
          recycling-center: recycling-center,
          timestamp: block-height,
          location: location,
          co2-impact: co2-impact,
          energy-impact: energy-impact,
          impact-score: impact-score,
          verified: true
        }
      )
      
      ;; Update user totals
      (update-user-totals user weight-grams co2-impact energy-impact impact-score)
      
      ;; Update daily activities
      (update-daily-activities user day weight-grams)
      
      ;; Update material statistics
      (update-material-statistics material-type weight-grams impact-score)
      
      ;; Update location statistics
      (update-location-statistics location impact-score)
      
      ;; Update recycling center stats
      (update-center-statistics recycling-center)
      
      ;; Update global counters
      (var-set activity-counter new-id)
      (var-set total-co2-saved (+ (var-get total-co2-saved) co2-impact))
      (var-set total-energy-saved (+ (var-get total-energy-saved) energy-impact))
      
      (ok new-id)
    )
  )
)

;; Update material impact rates (admin only)
(define-public (update-material-rates
  (material-type uint)
  (co2-per-gram uint)
  (energy-per-gram uint)
  (base-points uint)
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (<= material-type u6) ERR-INVALID-INPUT)
    
    (map-set material-impact-rates
      { material-type: material-type }
      {
        co2-per-gram: co2-per-gram,
        energy-per-gram: energy-per-gram,
        base-points: base-points
      }
    )
    (ok true)
  )
)

;; Batch record activities for recycling centers
(define-public (batch-record-activities
  (activities (list 10 {material-type: uint, weight-grams: uint, user: principal, location: (string-ascii 100)}))
)
  (let
    (
      (center tx-sender)
      (center-info (unwrap! (map-get? recycling-centers { center: center }) ERR-NOT-FOUND))
    )
    (asserts! (get verified center-info) ERR-CENTER-NOT-VERIFIED)
    (fold batch-process-activity activities (ok u0))
  )
)

;; Toggle contract active state (admin only)
(define-public (toggle-contract-state)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set contract-active (not (var-get contract-active)))
    (ok (var-get contract-active))
  )
)

;; Private helper functions

;; Calculate bonus score based on user activity patterns
(define-private (calculate-bonus-score (base-score uint) (user principal) (day uint))
  (let
    (
      (daily-activities (default-to { activity-count: u0, total-weight: u0 }
        (map-get? daily-user-activities { user: user, day: day })))
      (activity-bonus (if (> (get activity-count daily-activities) u5) u120 u100)) ;; 20% bonus for 5+ activities
    )
    (/ (* base-score activity-bonus) u100)
  )
)

;; Update user impact totals
(define-private (update-user-totals 
  (user principal) 
  (weight uint) 
  (co2-impact uint) 
  (energy-impact uint) 
  (impact-score uint)
)
  (let
    (
      (current-totals (default-to 
        { total-activities: u0, total-weight: u0, total-co2-saved: u0, 
          total-energy-saved: u0, total-impact-score: u0, last-activity: u0 }
        (map-get? user-impact-totals { user: user })))
    )
    (map-set user-impact-totals
      { user: user }
      {
        total-activities: (+ (get total-activities current-totals) u1),
        total-weight: (+ (get total-weight current-totals) weight),
        total-co2-saved: (+ (get total-co2-saved current-totals) co2-impact),
        total-energy-saved: (+ (get total-energy-saved current-totals) energy-impact),
        total-impact-score: (+ (get total-impact-score current-totals) impact-score),
        last-activity: block-height
      }
    )
  )
)

;; Update daily activity tracking
(define-private (update-daily-activities (user principal) (day uint) (weight uint))
  (let
    (
      (current-daily (default-to { activity-count: u0, total-weight: u0 }
        (map-get? daily-user-activities { user: user, day: day })))
    )
    (map-set daily-user-activities
      { user: user, day: day }
      {
        activity-count: (+ (get activity-count current-daily) u1),
        total-weight: (+ (get total-weight current-daily) weight)
      }
    )
  )
)

;; Update material statistics
(define-private (update-material-statistics (material-type uint) (weight uint) (impact uint))
  (let
    (
      (current-stats (default-to 
        { total-weight: u0, total-activities: u0, total-impact: u0, average-weight: u0 }
        (map-get? material-statistics { material-type: material-type })))
      (new-activities (+ (get total-activities current-stats) u1))
      (new-weight (+ (get total-weight current-stats) weight))
    )
    (map-set material-statistics
      { material-type: material-type }
      {
        total-weight: new-weight,
        total-activities: new-activities,
        total-impact: (+ (get total-impact current-stats) impact),
        average-weight: (/ new-weight new-activities)
      }
    )
  )
)

;; Update location statistics
(define-private (update-location-statistics (location (string-ascii 100)) (impact uint))
  (let
    (
      (current-stats (default-to 
        { total-activities: u0, total-impact: u0, active-users: u0 }
        (map-get? location-statistics { location: location })))
    )
    (map-set location-statistics
      { location: location }
      {
        total-activities: (+ (get total-activities current-stats) u1),
        total-impact: (+ (get total-impact current-stats) impact),
        active-users: (get active-users current-stats) ;; Updated separately
      }
    )
  )
)

;; Update recycling center statistics
(define-private (update-center-statistics (center principal))
  (map-set recycling-centers
    { center: center }
    (merge 
      (unwrap-panic (map-get? recycling-centers { center: center }))
      { total-activities: (+ (get total-activities (unwrap-panic (map-get? recycling-centers { center: center }))) u1) }
    )
  )
)

;; Batch processing helper
(define-private (batch-process-activity 
  (activity {material-type: uint, weight-grams: uint, user: principal, location: (string-ascii 100)})
  (result (response uint uint))
)
  (match result
    success (record-recycling-activity 
              (get material-type activity)
              (get weight-grams activity) 
              tx-sender 
              (get location activity))
    error (err error)
  )
)

;; Read-only functions

;; Get activity details
(define-read-only (get-activity (activity-id uint))
  (map-get? recycling-activities { activity-id: activity-id })
)

;; Get user impact summary
(define-read-only (get-user-impact-summary (user principal))
  (map-get? user-impact-totals { user: user })
)

;; Get recycling center info
(define-read-only (get-recycling-center-info (center principal))
  (map-get? recycling-centers { center: center })
)

;; Get material impact rates
(define-read-only (get-material-rates (material-type uint))
  (map-get? material-impact-rates { material-type: material-type })
)

;; Get daily user activities
(define-read-only (get-daily-activities (user principal) (day uint))
  (map-get? daily-user-activities { user: user, day: day })
)

;; Get material statistics
(define-read-only (get-material-statistics (material-type uint))
  (map-get? material-statistics { material-type: material-type })
)

;; Get location statistics
(define-read-only (get-location-statistics (location (string-ascii 100)))
  (map-get? location-statistics { location: location })
)

;; Get global statistics
(define-read-only (get-global-stats)
  {
    total-activities: (var-get activity-counter),
    total-co2-saved: (var-get total-co2-saved),
    total-energy-saved: (var-get total-energy-saved),
    contract-active: (var-get contract-active)
  }
)

;; Calculate user impact score for a specific period
(define-read-only (calculate-impact-score (user principal) (start-day uint) (end-day uint))
  (let
    (
      (user-totals (map-get? user-impact-totals { user: user }))
    )
    (match user-totals
      totals (ok (get total-impact-score totals))
      (ok u0)
    )
  )
)

;; Check if recycling center is verified
(define-read-only (is-center-verified (center principal))
  (match (map-get? recycling-centers { center: center })
    center-info (get verified center-info)
    false
  )
)

;; Get contract owner
(define-read-only (get-contract-owner)
  CONTRACT-OWNER
)
