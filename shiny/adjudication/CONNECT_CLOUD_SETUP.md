# Posit Connect Cloud deployment

This app is intended for deployment from the public GitHub repository on the branch:

`shiny-adjudication-interface`

Primary file:

`shiny/adjudication/app.R`

Connect Cloud requires `manifest.json` for R content.

## Required Connect Cloud secret variables

Add these under Advanced settings when publishing:

- `LEM_ACCESS_KEY_SHA256`
- `LEM_GOOGLE_SERVICE_ACCOUNT_JSON`
- `LEM_GOOGLE_SHEET_ID`
- `LEM_STORAGE_BACKEND`

Recommended values:

- `LEM_STORAGE_BACKEND=google_sheets`
- `LEM_GOOGLE_SHEET_ID=1x00D0idQz558dKp3gB0z-mcUBVrw8jjllqGAZdqYlcs`

`LEM_GOOGLE_SERVICE_ACCOUNT_JSON` should contain the complete Google service-account JSON object.

`LEM_ACCESS_KEY_SHA256` must contain the SHA-256 hash of the adjudication access key, not the plaintext key.

The app exposes no adjudication records until the access key is successfully verified for the current Shiny session.

## Publishing

In Connect Cloud:

1. Click **Publish**.
2. Select **Shiny**.
3. Select the public GitHub repository `thesalmonandthetomato/LivingEvidenceMap`.
4. Confirm branch `shiny-adjudication-interface`.
5. Select `shiny/adjudication/app.R` as the primary file.
6. Under **Advanced settings**, add the four variables above.
7. Publish.

Automatic republishing on pushes to this branch can remain enabled once the prototype is stable.
