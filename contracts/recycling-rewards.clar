;; Recycling Rewards Smart Contract
;; Manages token rewards for recycling activities with multi-tier incentives

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-NOT-FOUND (err u201))
(define-constant ERR-ALREADY-EXISTS (err u202))
(define-constant ERR-INVALID-INPUT (err u203))
(define-constant ERR-INSUFFICIENT-BALANCE (err u204))
(define-constant ERR-REWARD-COOLDOWN (err u205))
(define-constant ERR-STAKING-PERIOD (err u206))
(define-constant ERR-MILESTONE-NOT-REACHED (err u207))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant REWARD-TOKEN-NAME "RecycleToken")
(define-constant REWARD-TOKEN-SYMBOL "RCT")
(define-constant REWARD-TOKEN-DECIMALS u6)
(define-constant INITIAL-SUPPLY u1000000000000) ;; 1 million tokens with 6 decimals
(define-constant POINTS-TO-TOKEN-RATE u1000) ;; 1000 points = 1 token
(define-constant MIN-STAKE-PERIOD u1008) ;; ~7 days in blocks
(define-constant REFERRAL-BONUS u10) ;; 10% referral bonus

;; Tier definitions
(define-constant TIER-NOVICE u1)
(define-constant TIER-GUARDIAN u2)
(define-constant TIER-CHAMPION u3)
(define-constant TIER-HERO u4)

;; Data variables
(define-data-var total-supply uint INITIAL-SUPPLY)
(define-data-var total-rewards-distributed uint u0)
(define-data-var total-staked uint u0)
(define-data-var reward-pool uint u500000000000) ;; 50% of initial supply for rewards
(define-data-var referral-pool uint u100000000000) ;; 10% for referrals
(define-data-var contract-paused bool false)

;; Token balances and allowances
(define-map token-balances principal uint)
(define-map token-allowances { owner: principal, spender: principal } uint)

;; Reward system maps
(define-map user-rewards
  { user: principal }
  {
    total-earned: uint,
    total-claimed: uint,
    pending-rewards: uint,
    last-claim: uint,
    tier: uint,
    tier-multiplier: uint
  }
)

(define-map staking-positions
  { user: principal }
  {
    staked-amount: uint,
    stake-start: uint,
    stake-duration: uint,
    bonus-multiplier: uint,
    auto-compound: bool
  }
)

(define-map milestone-achievements
  { user: principal, milestone: uint }
  {
    achieved: bool,
    achieved-at: uint,
    reward-claimed: bool,
    reward-amount: uint
  }
)

(define-map referral-network
  { referrer: principal }
  {
    total-referrals: uint,
    total-referral-rewards: uint,
    active-referrals: uint
  }
)

(define-map user-referrals
  { user: principal }
  {
    referrer: (optional principal),
    referral-code: (string-ascii 20),
    join-date: uint,
    referral-tier: uint
  }
)

(define-map daily-reward-claims
  { user: principal, day: uint }
  { claimed: bool, amount: uint }
)

(define-map tier-thresholds
  { tier: uint }
  {
    min-points: uint,
    max-points: uint,
    multiplier: uint,
    stake-bonus: uint
  }
)

(define-map weekly-challenges
  { week: uint, challenge-type: uint }
  {
    description: (string-ascii 200),
    target-amount: uint,
    reward-per-unit: uint,
    active: bool,
    participants: uint
  }
)

;; Initialize tier thresholds
(map-set tier-thresholds { tier: TIER-NOVICE }
  { min-points: u0, max-points: u100, multiplier: u100, stake-bonus: u105 }) ;; 1x rewards, 5% stake bonus
(map-set tier-thresholds { tier: TIER-GUARDIAN }
  { min-points: u101, max-points: u500, multiplier: u120, stake-bonus: u110 }) ;; 1.2x rewards, 10% stake bonus
(map-set tier-thresholds { tier: TIER-CHAMPION }
  { min-points: u501, max-points: u1000, multiplier: u150, stake-bonus: u115 }) ;; 1.5x rewards, 15% stake bonus
(map-set tier-thresholds { tier: TIER-HERO }
  { min-points: u1001, max-points: u999999, multiplier: u200, stake-bonus: u125 }) ;; 2x rewards, 25% stake bonus

;; Initialize token owner balance
(map-set token-balances CONTRACT-OWNER INITIAL-SUPPLY)

;; Public functions

;; Process recycling rewards based on impact score
(define-public (process-recycling-reward (user principal) (impact-score uint))
  (let
    (
      (user-reward-info (default-to 
        { total-earned: u0, total-claimed: u0, pending-rewards: u0, 
          last-claim: u0, tier: TIER-NOVICE, tier-multiplier: u100 }
        (map-get? user-rewards { user: user })))
      (current-tier (calculate-user-tier user impact-score))
      (tier-info (unwrap! (map-get? tier-thresholds { tier: current-tier }) ERR-NOT-FOUND))
      (base-reward (/ impact-score POINTS-TO-TOKEN-RATE))
      (tier-multiplier (get multiplier tier-info))
      (staking-bonus (get-staking-bonus user))
      (final-reward (apply-all-bonuses base-reward tier-multiplier staking-bonus user))
    )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (> impact-score u0) ERR-INVALID-INPUT)
    
    ;; Update user rewards
    (map-set user-rewards
      { user: user }
      {
        total-earned: (+ (get total-earned user-reward-info) final-reward),
        total-claimed: (get total-claimed user-reward-info),
        pending-rewards: (+ (get pending-rewards user-reward-info) final-reward),
        last-claim: (get last-claim user-reward-info),
        tier: current-tier,
        tier-multiplier: tier-multiplier
      }
    )
    
    ;; Process referral rewards
    (try! (process-referral-reward user final-reward))
    
    ;; Check and process milestone achievements
    (unwrap-panic (check-milestone-achievements user (get total-earned user-reward-info)))
    
    (ok final-reward)
  )
)

;; Claim pending rewards
(define-public (claim-rewards)
  (let
    (
      (user tx-sender)
      (user-reward-info (unwrap! (map-get? user-rewards { user: user }) ERR-NOT-FOUND))
      (pending-amount (get pending-rewards user-reward-info))
      (day (/ block-height u144))
    )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (> pending-amount u0) ERR-INSUFFICIENT-BALANCE)
    (asserts! (>= (var-get reward-pool) pending-amount) ERR-INSUFFICIENT-BALANCE)
    
    ;; Check daily claim limit (prevent multiple claims per day)
    (asserts! (is-none (map-get? daily-reward-claims { user: user, day: day })) ERR-REWARD-COOLDOWN)
    
    ;; Transfer tokens to user
    (try! (transfer-tokens CONTRACT-OWNER user pending-amount))
    
    ;; Update reward pool and user rewards
    (var-set reward-pool (- (var-get reward-pool) pending-amount))
    (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) pending-amount))
    
    ;; Update user reward record
    (map-set user-rewards
      { user: user }
      (merge user-reward-info {
        total-claimed: (+ (get total-claimed user-reward-info) pending-amount),
        pending-rewards: u0,
        last-claim: block-height
      })
    )
    
    ;; Record daily claim
    (map-set daily-reward-claims
      { user: user, day: day }
      { claimed: true, amount: pending-amount }
    )
    
    (ok pending-amount)
  )
)

;; Stake tokens for enhanced rewards
(define-public (stake-tokens (amount uint) (duration uint) (auto-compound bool))
  (let
    (
      (user tx-sender)
      (user-balance (get-token-balance user))
      (current-stake (map-get? staking-positions { user: user }))
    )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (>= user-balance amount) ERR-INSUFFICIENT-BALANCE)
    (asserts! (>= duration MIN-STAKE-PERIOD) ERR-INVALID-INPUT)
    (asserts! (is-none current-stake) ERR-ALREADY-EXISTS)
    
    ;; Transfer tokens to contract for staking
    (try! (transfer-tokens user (as-contract tx-sender) amount))
    
    ;; Calculate staking bonus multiplier
    (let
      (
        (user-tier (get tier (default-to 
          { total-earned: u0, total-claimed: u0, pending-rewards: u0, 
            last-claim: u0, tier: TIER-NOVICE, tier-multiplier: u100 }
          (map-get? user-rewards { user: user }))))
        (tier-info (unwrap! (map-get? tier-thresholds { tier: user-tier }) ERR-NOT-FOUND))
        (base-bonus (get stake-bonus tier-info))
        (duration-bonus (calculate-duration-bonus duration))
        (final-bonus (+ base-bonus duration-bonus))
      )
      
      ;; Create staking position
      (map-set staking-positions
        { user: user }
        {
          staked-amount: amount,
          stake-start: block-height,
          stake-duration: duration,
          bonus-multiplier: final-bonus,
          auto-compound: auto-compound
        }
      )
      
      ;; Update total staked
      (var-set total-staked (+ (var-get total-staked) amount))
      
      (ok final-bonus)
    )
  )
)

;; Unstake tokens after staking period
(define-public (unstake-tokens)
  (let
    (
      (user tx-sender)
      (stake-position (unwrap! (map-get? staking-positions { user: user }) ERR-NOT-FOUND))
      (stake-end (+ (get stake-start stake-position) (get stake-duration stake-position)))
      (staked-amount (get staked-amount stake-position))
    )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (>= block-height stake-end) ERR-STAKING-PERIOD)
    
    ;; Transfer staked tokens back to user
    (try! (as-contract (transfer-tokens tx-sender user staked-amount)))
    
    ;; Calculate and distribute staking rewards
    (let
      (
        (staking-reward (calculate-staking-reward stake-position))
      )
      (if (> staking-reward u0)
        (try! (as-contract (transfer-tokens tx-sender user staking-reward)))
        true
      )
    )
    
    ;; Remove staking position and update totals
    (map-delete staking-positions { user: user })
    (var-set total-staked (- (var-get total-staked) staked-amount))
    
    (ok staked-amount)
  )
)

;; Create referral program
(define-public (create-referral (referrer principal) (referral-code (string-ascii 20)))
  (let
    (
      (user tx-sender)
    )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (is-none (map-get? user-referrals { user: user })) ERR-ALREADY-EXISTS)
    (asserts! (> (len referral-code) u0) ERR-INVALID-INPUT)
    (asserts! (not (is-eq user referrer)) ERR-INVALID-INPUT)
    
    ;; Create referral relationship
    (map-set user-referrals
      { user: user }
      {
        referrer: (some referrer),
        referral-code: referral-code,
        join-date: block-height,
        referral-tier: u1
      }
    )
    
    ;; Update referrer's network
    (let
      (
        (referrer-network (default-to 
          { total-referrals: u0, total-referral-rewards: u0, active-referrals: u0 }
          (map-get? referral-network { referrer: referrer })))
      )
      (map-set referral-network
        { referrer: referrer }
        {
          total-referrals: (+ (get total-referrals referrer-network) u1),
          total-referral-rewards: (get total-referral-rewards referrer-network),
          active-referrals: (+ (get active-referrals referrer-network) u1)
        }
      )
    )
    
    (ok true)
  )
)

;; Claim milestone rewards
(define-public (claim-milestone-reward (milestone uint))
  (let
    (
      (user tx-sender)
      (achievement (unwrap! (map-get? milestone-achievements { user: user, milestone: milestone }) ERR-NOT-FOUND))
    )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (get achieved achievement) ERR-MILESTONE-NOT-REACHED)
    (asserts! (not (get reward-claimed achievement)) ERR-ALREADY-EXISTS)
    
    (let
      (
        (reward-amount (get reward-amount achievement))
      )
      ;; Transfer milestone reward
      (try! (transfer-tokens CONTRACT-OWNER user reward-amount))
      
      ;; Mark reward as claimed
      (map-set milestone-achievements
        { user: user, milestone: milestone }
        (merge achievement { reward-claimed: true })
      )
      
      (ok reward-amount)
    )
  )
)

;; Admin function to add weekly challenges
(define-public (create-weekly-challenge
  (week uint)
  (challenge-type uint)
  (description (string-ascii 200))
  (target-amount uint)
  (reward-per-unit uint)
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-none (map-get? weekly-challenges { week: week, challenge-type: challenge-type })) ERR-ALREADY-EXISTS)
    
    (map-set weekly-challenges
      { week: week, challenge-type: challenge-type }
      {
        description: description,
        target-amount: target-amount,
        reward-per-unit: reward-per-unit,
        active: true,
        participants: u0
      }
    )
    (ok true)
  )
)

;; Pause/unpause contract (admin only)
(define-public (toggle-contract-state)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set contract-paused (not (var-get contract-paused)))
    (ok (var-get contract-paused))
  )
)

;; Private helper functions

;; Calculate user tier based on total impact score
(define-private (calculate-user-tier (user principal) (current-score uint))
  (let
    (
      (user-totals (map-get? user-rewards { user: user }))
      (total-score (match user-totals
        some-totals (+ (get total-earned some-totals) current-score)
        current-score))
    )
    (if (<= total-score u100) TIER-NOVICE
      (if (<= total-score u500) TIER-GUARDIAN
        (if (<= total-score u1000) TIER-CHAMPION
          TIER-HERO)))
  )
)

;; Get staking bonus multiplier for user
(define-private (get-staking-bonus (user principal))
  (match (map-get? staking-positions { user: user })
    stake-info (get bonus-multiplier stake-info)
    u100 ;; No staking bonus
  )
)

;; Apply all bonuses to base reward
(define-private (apply-all-bonuses (base-reward uint) (tier-multiplier uint) (staking-bonus uint) (user principal))
  (let
    (
      (tier-reward (/ (* base-reward tier-multiplier) u100))
      (final-reward (/ (* tier-reward staking-bonus) u100))
    )
    final-reward
  )
)

;; Process referral rewards
(define-private (process-referral-reward (user principal) (reward-amount uint))
  (match (map-get? user-referrals { user: user })
    referral-info
    (match (get referrer referral-info)
      referrer
      (let
        (
          (referral-reward (/ (* reward-amount REFERRAL-BONUS) u100))
          (referrer-network (default-to 
            { total-referrals: u0, total-referral-rewards: u0, active-referrals: u0 }
            (map-get? referral-network { referrer: referrer })))
        )
        (if (and (>= (var-get referral-pool) referral-reward) (> referral-reward u0))
          (begin
            (try! (transfer-tokens CONTRACT-OWNER referrer referral-reward))
            (var-set referral-pool (- (var-get referral-pool) referral-reward))
            (map-set referral-network
              { referrer: referrer }
              (merge referrer-network {
                total-referral-rewards: (+ (get total-referral-rewards referrer-network) referral-reward)
              })
            )
            (ok true)
          )
          (ok true)
        )
      )
      (ok true)
    )
    (ok true)
  )
)

;; Check and process milestone achievements
(define-private (check-milestone-achievements (user principal) (total-earned uint))
  (let
    (
      (milestones (list u1000 u5000 u10000 u25000 u50000 u100000)) ;; Milestone points
    )
    (fold check-single-milestone milestones (ok true))
  )
)

;; Check single milestone
(define-private (check-single-milestone (milestone uint) (result (response bool uint)))
  ;; Placeholder implementation - would check if user reached milestone
  (ok true)
)

;; Calculate duration bonus for staking
(define-private (calculate-duration-bonus (duration uint))
  (let
    (
      (weeks (/ duration u1008)) ;; blocks per week
    )
    (if (>= weeks u52) u25      ;; 25% bonus for 1 year
      (if (>= weeks u26) u15    ;; 15% bonus for 6 months
        (if (>= weeks u12) u10  ;; 10% bonus for 3 months
          (if (>= weeks u4) u5  ;; 5% bonus for 1 month
            u0))))             ;; No bonus for less than 1 month
  )
)

;; Calculate staking reward
(define-private (calculate-staking-reward (stake-position {staked-amount: uint, stake-start: uint, stake-duration: uint, bonus-multiplier: uint, auto-compound: bool}))
  (let
    (
      (staked-amount (get staked-amount stake-position))
      (duration (get stake-duration stake-position))
      (bonus-multiplier (get bonus-multiplier stake-position))
      (base-reward (/ (* staked-amount u5) u100)) ;; 5% base annual reward
      (time-factor (/ duration u52560)) ;; blocks in a year
      (final-reward (/ (* (* base-reward time-factor) bonus-multiplier) u100))
    )
    final-reward
  )
)

;; Token transfer helper
(define-private (transfer-tokens (from principal) (to principal) (amount uint))
  (let
    (
      (from-balance (get-token-balance from))
      (to-balance (get-token-balance to))
    )
    (asserts! (>= from-balance amount) ERR-INSUFFICIENT-BALANCE)
    
    (map-set token-balances from (- from-balance amount))
    (map-set token-balances to (+ to-balance amount))
    
    (ok true)
  )
)

;; Read-only functions

;; Get token balance
(define-read-only (get-token-balance (user principal))
  (default-to u0 (map-get? token-balances user))
)

;; Get user reward information
(define-read-only (get-user-rewards (user principal))
  (map-get? user-rewards { user: user })
)

;; Get staking position
(define-read-only (get-staking-position (user principal))
  (map-get? staking-positions { user: user })
)

;; Get referral information
(define-read-only (get-referral-info (user principal))
  (map-get? user-referrals { user: user })
)

;; Get referral network
(define-read-only (get-referral-network (referrer principal))
  (map-get? referral-network { referrer: referrer })
)

;; Get tier information
(define-read-only (get-tier-info (tier uint))
  (map-get? tier-thresholds { tier: tier })
)

;; Get milestone achievement
(define-read-only (get-milestone-achievement (user principal) (milestone uint))
  (map-get? milestone-achievements { user: user, milestone: milestone })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-supply: (var-get total-supply),
    total-rewards-distributed: (var-get total-rewards-distributed),
    total-staked: (var-get total-staked),
    reward-pool: (var-get reward-pool),
    referral-pool: (var-get referral-pool),
    contract-paused: (var-get contract-paused)
  }
)

;; Calculate pending rewards for user
(define-read-only (calculate-pending-rewards (user principal))
  (match (map-get? user-rewards { user: user })
    reward-info (get pending-rewards reward-info)
    u0
  )
)

;; Get weekly challenge
(define-read-only (get-weekly-challenge (week uint) (challenge-type uint))
  (map-get? weekly-challenges { week: week, challenge-type: challenge-type })
)
