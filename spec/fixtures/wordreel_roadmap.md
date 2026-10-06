# WordReel — Development Roadmap & Implementation Steps

This document outlines the step-by-step technical and design roadmap for building **WordReel**, a fast-paced 1D word reel game for mobile platforms.

---

## Technical Stack Recommendation

* **Engine:** TBD
* **Target Platforms:** iOS
* **Language:** Swift
* **Data Storage:** SQLite or JSON for local word dictionary and player stats; Cloud Firestore / Supabase for daily leaderboard/challenges.

---

## Phase 1: Engine Setup & Core Reel Mechanics

### Step 1: Project Setup & Viewport
- Set project aspect ratio to portrait (19:9 for modern smartphones).
- Configure camera for fixed aerial view.
- Create base UI canvas and layout boundaries.

### Step 2: Cube Data Structure & Rotations
- Define a `CubeTile` class containing:
  - `faces`: List/Array of 6 characters (e.g., `['T', 'R', 'A', 'P', ' ', 'S']`).
  - `currentIndex`: Pointer to the active face visible on screen.
- Implement rotation logic:
  - On tap event: Increment `currentIndex` (wrapping around to `0`).
  - Trigger vertical flip animation along the Y-axis (top to bottom).
  - Render semi-transparent previews (35% opacity) of `currentIndex - 1` (above) and `currentIndex + 1` (below).

### Step 3: 1D Reel Controller
- Instantiate an array of `N` cubes horizontally (e.g., 6 or 7 cubes).
- Add layout auto-scaling so the reel fits nicely across various screen widths.

---

## Phase 2: Game Logic & Dictionary Validation

### Step 4: Word Validation Engine
- Integrated Trie data structure or Hash Set for instant $O(1)$ word lookups.
- On every tap rotation:
  - Construct string from current active faces across all cubes.
  - Split string using blank spaces (`' '`) as delimiters.
  - Check extracted sub-words against active target checklist.

### Step 5: Target Generator & Solvability Algorithm
- Build a level generator that picks target words and guarantees at least one sequence of rotations yields all targets.
- Assign characters to faces such that red herrings exist, maintaining puzzle friction.

---

## Phase 3: Game Loop & UI/UX

### Step 6: Compact Target List UI
- Build a horizontal scrolling badge container at the top of the viewport.
- Animate badges when a target word is successfully formed (pop effect, strike-through, or green highlight).

### Step 7: Timer & Arcade Scoring
- Implement a 3:00 minute countdown loop.
- Scoring system logic:
  - Base points per target word formed (scaled by word length).
  - Multiplier increment for fast consecutive matches.
  - Bonus seconds added (+2s) on fast match.
- State management: `Start` -> `Playing` -> `Game Over`.

---

## Phase 4: Polish, Haptics & Visuals

### Step 8: Audio & Tactile Feedback
- Light haptic pulse on cube tap rotation.
- Distinct audio pitch per cube tap, ascending in scale as combo multiplier increases.
- Satisfying completion sound and particle burst on matching a word.

### Step 9: Visual Juice & Micro-Interactions
- Smooth spring/interpolation animations for cube flips.
- Transition animations when replacing cubes or shifting to a new set of words.

---

## Phase 5: Virality Engine & Social Features

### Step 10: Seed-Based Daily Challenge
- Implement deterministic puzzle generation using a daily date seed (e.g., `YYYY-MM-DD`).
- Ensure all players worldwide get the exact same sequence for the Daily Sprint.

### Step 11: Shareable Scorecard & Replay
- Generate text-based scorecard summary formatted for messaging apps:
  ```text
  WordReel #142 ⚡ 14 Words | 2,840 pts
  🟩🟩🟨🟩🟨🟩 24.2s (Peak Speed: 3.2 taps/sec)
  Can you beat my score? https://wordreel.app/play?seed=142
  ```
- Implement deep-linking to allow players to directly challenge friends with custom seeds.

---

## Phase 6: QA, Optimization & Launch

### Step 12: Performance Optimization & Testing
- Target 60 FPS minimum on low-end iOS
- Test touch registers to handle hyper-fast multi-finger tapping.
- Internal beta testing (TestFlight).

### Step 13: App Store Deployment
- Prepare store assets (screenshots, preview videos, app icons).
- Submit for App Store.
