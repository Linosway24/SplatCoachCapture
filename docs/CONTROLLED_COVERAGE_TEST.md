# Controlled Four-Direction Coverage Test

Use this test to validate the existing relative-yaw sector mapping. It is a
diagnostic procedure, not a normal room scan, and it does not validate physical
movement around a room.

## Setup

1. Install the current build on a physical iPhone.
2. Stand in one place with the phone upright.
3. Choose a recognizable surface as the start wall.
4. Start a new scan while facing that wall.

## Procedure

1. Face the start wall and hold still for 10 seconds.
2. Rotate 90 degrees right and hold for 10 seconds.
3. Rotate another 90 degrees right and hold for 10 seconds.
4. Rotate another 90 degrees right and hold for 10 seconds.
5. Return to the start direction and hold for 10 seconds.
6. Stop and export the scan.

Do not walk, reverse direction, or tap to focus during this test. Rotate at a
steady pace and make each hold visually obvious in the saved images.

## Expected diagnostic result

Review `coverage_frame_diagnostics.csv` and `coverage_diagnostics.json`:

- The first hold should normalize near 0 degrees and map to `startWall`.
- The second should normalize near 90 degrees and map to `rightSide`.
- The third should normalize near 180 degrees and map to `oppositeWall`.
- The fourth should normalize near 270 degrees and map to `leftSide`.
- The final hold should wrap back near 0/360 degrees and map to `startWall`.

Boundary ranges are exported with the data. Frames close to 45, 135, 225, or
315 degrees may legitimately fall on either side as the phone settles; the
middle of each 10-second hold should not.

## What this test does not prove

- That relative yaw corresponds to the user's physical location in a room.
- That Core Motion yaw will not drift during a long capture.
- That new-angle or overlap thresholds are correctly tuned.
- That the current movement weighting is correct.

Do not tune those behaviors until this test establishes that yaw normalization
and sector assignment are recorded consistently.
