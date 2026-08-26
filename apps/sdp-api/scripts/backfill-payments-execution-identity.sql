\set ON_ERROR_STOP on

-- Idempotent HOO-1023 K3 catch-up. Run after old HTTP/cron executions and
-- leases have drained, then run audit-payments-execution-identity.sql.

\echo '=== Payments exact identity before catch-up ==='
SELECT
  (SELECT COUNT(*) FROM payment_transfers WHERE custody_wallet_id IS NULL)
    AS transfers_without_exact_wallet,
  (SELECT COUNT(*) FROM payment_transfer_batches WHERE source_custody_wallet_id IS NULL)
    AS batches_without_exact_wallet,
  (SELECT COUNT(*) FROM payment_requests WHERE custody_wallet_id IS NULL)
    AS requests_without_exact_wallet;

BEGIN;

CREATE TEMP VIEW k3_payments_wallet_scope AS
SELECT
    wallet.id,
    wallet.wallet_id,
    wallet.public_key,
    config.organization_id,
    config.project_id,
    'config'::TEXT AS owner_kind
FROM custody_wallets wallet
JOIN custody_configs config ON config.id = wallet.custody_config_id
UNION ALL
SELECT
    wallet.id,
    wallet.wallet_id,
    wallet.public_key,
    connection.organization_id,
    connection.project_id,
    'connection'::TEXT AS owner_kind
FROM custody_wallets wallet
JOIN custody_connections connection ON connection.id = wallet.custody_connection_id;

WITH unique_matches AS (
    SELECT transfer.id AS transfer_id, MIN(wallet.id) AS custody_wallet_id
    FROM payment_transfers transfer
    JOIN k3_payments_wallet_scope wallet
      ON wallet.organization_id = transfer.organization_id
     AND (
          (wallet.owner_kind = 'config'
           AND (wallet.project_id = transfer.project_id OR wallet.project_id IS NULL))
          OR
          (wallet.owner_kind = 'connection' AND wallet.project_id = transfer.project_id)
     )
     AND wallet.wallet_id = transfer.wallet_id
     AND wallet.public_key = CASE
          WHEN transfer.direction = 'inbound' THEN transfer.destination_address
          ELSE transfer.source_address
     END
    WHERE transfer.custody_wallet_id IS NULL
    GROUP BY transfer.id
    HAVING COUNT(*) = 1
)
UPDATE payment_transfers transfer
SET custody_wallet_id = unique_matches.custody_wallet_id
FROM unique_matches
WHERE transfer.id = unique_matches.transfer_id
  AND transfer.custody_wallet_id IS NULL;

WITH unique_matches AS (
    SELECT batch.id AS batch_id, MIN(wallet.id) AS custody_wallet_id
    FROM payment_transfer_batches batch
    JOIN k3_payments_wallet_scope wallet
      ON wallet.organization_id = batch.organization_id
     AND (
          (wallet.owner_kind = 'config'
           AND (wallet.project_id = batch.project_id OR wallet.project_id IS NULL))
          OR
          (wallet.owner_kind = 'connection' AND wallet.project_id = batch.project_id)
     )
     AND wallet.wallet_id = batch.source_wallet_id
     AND wallet.public_key = batch.source_address
    WHERE batch.source_custody_wallet_id IS NULL
    GROUP BY batch.id
    HAVING COUNT(*) = 1
)
UPDATE payment_transfer_batches batch
SET source_custody_wallet_id = unique_matches.custody_wallet_id
FROM unique_matches
WHERE batch.id = unique_matches.batch_id
  AND batch.source_custody_wallet_id IS NULL;

WITH unique_matches AS (
    SELECT request.id AS request_id, MIN(wallet.id) AS custody_wallet_id
    FROM payment_requests request
    JOIN k3_payments_wallet_scope wallet
      ON wallet.organization_id = request.organization_id
     AND (
          (wallet.owner_kind = 'config'
           AND (wallet.project_id = request.project_id OR wallet.project_id IS NULL))
          OR
          (wallet.owner_kind = 'connection' AND wallet.project_id = request.project_id)
     )
     AND wallet.wallet_id = request.wallet_id
     AND wallet.public_key = request.destination_address
    WHERE request.custody_wallet_id IS NULL
    GROUP BY request.id
    HAVING COUNT(*) = 1
)
UPDATE payment_requests request
SET custody_wallet_id = unique_matches.custody_wallet_id
FROM unique_matches
WHERE request.id = unique_matches.request_id
  AND request.custody_wallet_id IS NULL;

UPDATE payment_requests
SET status = 'canceled',
    canceled_by = NULL,
    lifecycle = lifecycle || jsonb_build_array(
        jsonb_build_object(
            'status', 'canceled',
            'at', sdp_iso_now()
        )
    ),
    updated_at = sdp_iso_now()
WHERE status = 'awaiting_payment'
  AND custody_wallet_id IS NULL;

CREATE TEMP TABLE k3_payment_operation_resolution ON COMMIT DROP AS
SELECT
    operation.id,
    COALESCE(
        operation.custody_wallet_id,
        CASE WHEN matches.match_count = 1 THEN matches.custody_wallet_id END
    ) AS resolved_custody_wallet_id,
    operation.raw_payload ->> 'source' = operation.wallet_id
        AND jsonb_typeof(operation.raw_payload -> 'executionRequest') = 'object'
        AND operation.raw_payload #>> '{executionRequest,method}' = 'POST'
        AND (
            (operation.operation_type = 'payment_transfer_execute'
             AND operation.raw_payload #>> '{executionRequest,path}' = '/v1/payments/transfers')
            OR
            (operation.operation_type = 'payment_transfer_batch_execute'
             AND operation.raw_payload #>> '{executionRequest,path}' = '/v1/payments/transfer-batches')
        )
        AND jsonb_typeof(operation.raw_payload #> '{executionRequest,body}') = 'object'
        AND operation.raw_payload #>> '{executionRequest,body,source}' = operation.wallet_id
        AND jsonb_typeof(operation.raw_payload #> '{executionRequest,idempotencyKey}') = 'string'
      AS legacy_envelope_valid,
    jsonb_typeof(operation.raw_payload -> 'executionRequest') = 'object'
        AND operation.raw_payload #>> '{executionRequest,method}' = 'POST'
        AND (
            (operation.operation_type = 'payment_transfer_execute'
             AND operation.raw_payload #>> '{executionRequest,path}' = '/v1/payments/transfers')
            OR
            (operation.operation_type = 'payment_transfer_batch_execute'
             AND operation.raw_payload #>> '{executionRequest,path}' = '/v1/payments/transfer-batches')
        )
        AND jsonb_typeof(operation.raw_payload #> '{executionRequest,body}') = 'object'
        AND jsonb_typeof(operation.raw_payload #> '{executionRequest,idempotencyKey}') = 'string'
        AND NOT (operation.raw_payload ? 'source')
        AND NOT ((operation.raw_payload #> '{executionRequest,body}') ? 'source')
        AND operation.raw_payload ->> 'sourceCustodyWalletId' = COALESCE(
            operation.custody_wallet_id,
            CASE WHEN matches.match_count = 1 THEN matches.custody_wallet_id END
        )
        AND operation.raw_payload #>> '{executionRequest,body,sourceCustodyWalletId}' = COALESCE(
            operation.custody_wallet_id,
            CASE WHEN matches.match_count = 1 THEN matches.custody_wallet_id END
        )
      AS exact_envelope_valid
FROM wallet_operations operation
LEFT JOIN LATERAL (
    SELECT COUNT(*)::INTEGER AS match_count, MIN(wallet.id) AS custody_wallet_id
    FROM k3_payments_wallet_scope wallet
    WHERE operation.custody_wallet_id IS NULL
      AND wallet.organization_id = operation.organization_id
      AND (
           (wallet.owner_kind = 'config'
            AND (wallet.project_id = operation.project_id OR wallet.project_id IS NULL))
           OR
           (wallet.owner_kind = 'connection' AND wallet.project_id = operation.project_id)
      )
      AND wallet.wallet_id = operation.wallet_id
      AND wallet.public_key = operation.raw_payload #>> '{context,sourceAddress}'
) matches ON TRUE
WHERE operation.operation_type IN (
    'payment_transfer_execute',
    'payment_transfer_batch_execute'
)
  AND operation.status IN ('pending_approval', 'executing');

UPDATE wallet_operations operation
SET custody_wallet_id = resolution.resolved_custody_wallet_id,
    raw_payload = CASE
        WHEN COALESCE(resolution.legacy_envelope_valid, false) THEN jsonb_set(
            (operation.raw_payload - 'source')
              || jsonb_build_object(
                  'sourceCustodyWalletId', resolution.resolved_custody_wallet_id
              ),
            '{executionRequest,body}',
            ((operation.raw_payload #> '{executionRequest,body}') - 'source')
              || jsonb_build_object(
                  'sourceCustodyWalletId', resolution.resolved_custody_wallet_id
              ),
            false
        )
        ELSE operation.raw_payload
    END,
    updated_at = sdp_iso_now()
FROM k3_payment_operation_resolution resolution
WHERE operation.id = resolution.id
  AND resolution.resolved_custody_wallet_id IS NOT NULL
  AND (
      COALESCE(resolution.legacy_envelope_valid, false)
      OR (
          operation.custody_wallet_id IS NULL
          AND COALESCE(resolution.exact_envelope_valid, false)
      )
  )
  AND operation.execution_effect_started_at IS NULL
  AND (
      operation.status = 'pending_approval'
      OR (
          operation.status = 'executing'
          AND (
              operation.execution_lease_expires_at IS NULL
              OR operation.execution_lease_expires_at <= sdp_iso_now()
          )
      )
  );

UPDATE approval_requests approval
SET status = 'canceled',
    resolved_at = sdp_iso_now(),
    updated_at = sdp_iso_now()
FROM k3_payment_operation_resolution resolution
JOIN wallet_operations operation ON operation.id = resolution.id
WHERE approval.wallet_operation_id = operation.id
  AND approval.status = 'pending'
  AND operation.status = 'pending_approval'
  AND operation.execution_effect_started_at IS NULL
  AND NOT (
      (resolution.resolved_custody_wallet_id IS NOT NULL
       AND COALESCE(resolution.legacy_envelope_valid, false))
      OR COALESCE(resolution.exact_envelope_valid, false)
  );

UPDATE wallet_operations operation
SET status = 'canceled',
    execution_error = 'Legacy Payments approval could not be attributed to exactly one SDP wallet',
    updated_at = sdp_iso_now()
FROM k3_payment_operation_resolution resolution
WHERE operation.id = resolution.id
  AND operation.status = 'pending_approval'
  AND operation.execution_effect_started_at IS NULL
  AND NOT (
      (resolution.resolved_custody_wallet_id IS NOT NULL
       AND COALESCE(resolution.legacy_envelope_valid, false))
      OR COALESCE(resolution.exact_envelope_valid, false)
  );

UPDATE wallet_operations operation
SET status = 'failed',
    execution_completed_at = sdp_iso_now(),
    execution_error = 'Legacy Payments execution could not be attributed to exactly one SDP wallet',
    execution_lease_expires_at = NULL,
    updated_at = sdp_iso_now()
FROM k3_payment_operation_resolution resolution
WHERE operation.id = resolution.id
  AND operation.status = 'executing'
  AND operation.execution_effect_started_at IS NULL
  AND (
      operation.execution_lease_expires_at IS NULL
      OR operation.execution_lease_expires_at <= sdp_iso_now()
  )
  AND NOT (
      (resolution.resolved_custody_wallet_id IS NOT NULL
       AND COALESCE(resolution.legacy_envelope_valid, false))
      OR COALESCE(resolution.exact_envelope_valid, false)
  );

DROP TABLE k3_payment_operation_resolution;
DROP VIEW k3_payments_wallet_scope;

COMMIT;

\echo '=== Payments exact identity after catch-up ==='
SELECT
  (SELECT COUNT(*) FROM payment_transfers WHERE custody_wallet_id IS NULL)
    AS transfers_without_exact_wallet,
  (SELECT COUNT(*) FROM payment_transfer_batches WHERE source_custody_wallet_id IS NULL)
    AS batches_without_exact_wallet,
  (SELECT COUNT(*) FROM payment_requests WHERE custody_wallet_id IS NULL)
    AS requests_without_exact_wallet;
