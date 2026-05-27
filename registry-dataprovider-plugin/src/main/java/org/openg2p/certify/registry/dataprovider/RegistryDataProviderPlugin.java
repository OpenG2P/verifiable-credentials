package org.openg2p.certify.registry.dataprovider;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import javax.sql.DataSource;

import org.json.JSONObject;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.jdbc.DataSourceBuilder;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import io.mosip.certify.api.exception.DataProviderExchangeException;
import io.mosip.certify.api.spi.DataProviderPlugin;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;

/**
 * Inji Certify {@link DataProviderPlugin} that fetches a citizen's VC claims from an external
 * OpenG2P Registry database.
 *
 * <p><b>Configurable, nothing hardcoded:</b>
 * <ul>
 *   <li>{@code mosip.certify.data-provider-plugin.scope-query-mapping} — one SQL query per
 *       credential scope. The table/view, joins and filters all live in the SQL, so the plugin
 *       is schema-agnostic.</li>
 *   <li>{@code mosip.certify.data-provider-plugin.param-claim-mapping} — maps each SQL named
 *       parameter to the access-token claim it should be bound from
 *       (e.g. {@code {'id':'phone_number'}}). This removes the stock Postgres plugin's hardcoded
 *       {@code :id = sub}.</li>
 * </ul>
 *
 * <p><b>Important:</b> the external datasource is built and held <em>privately</em> by this plugin
 * (NOT exposed as a Spring {@code DataSource} bean). Exposing a {@code DataSource} bean would trip
 * Spring Boot's {@code @ConditionalOnMissingBean(DataSource)} and suppress Certify's own primary
 * datasource. Keeping it private leaves Certify's datasource / keymanager completely untouched.
 */
@Component
@ConditionalOnProperty(value = "mosip.certify.integration.data-provider-plugin",
        havingValue = "RegistryDataProviderPlugin")
public class RegistryDataProviderPlugin implements DataProviderPlugin {

    private static final Logger log = LoggerFactory.getLogger(RegistryDataProviderPlugin.class);

    @Value("${mosip.certify.data-provider-plugin.registrydb.url}")
    private String dbUrl;

    @Value("${mosip.certify.data-provider-plugin.registrydb.username}")
    private String dbUsername;

    @Value("${mosip.certify.data-provider-plugin.registrydb.password}")
    private String dbPassword;

    @Value("${mosip.certify.data-provider-plugin.registrydb.driver-class-name:org.postgresql.Driver}")
    private String dbDriverClassName;

    /** scope -> SQL query (named parameters, e.g. :id). */
    @Value("#{${mosip.certify.data-provider-plugin.scope-query-mapping}}")
    private LinkedHashMap<String, String> scopeQueryMapping;

    /** SQL param name -> access-token claim name (e.g. {'id':'phone_number'}). */
    @Value("#{${mosip.certify.data-provider-plugin.param-claim-mapping}}")
    private LinkedHashMap<String, String> paramClaimMapping;

    private DataSource dataSource;
    private NamedParameterJdbcTemplate jdbc;

    @PostConstruct
    void initDatasource() {
        // Built privately — NOT a Spring bean — so Certify's own datasource is untouched.
        this.dataSource = DataSourceBuilder.create()
                .url(dbUrl)
                .username(dbUsername)
                .password(dbPassword)
                .driverClassName(dbDriverClassName)
                .build();
        this.jdbc = new NamedParameterJdbcTemplate(this.dataSource);
        log.info("RegistryDataProviderPlugin initialised; external datasource configured for {}", dbUrl);
    }

    @PreDestroy
    void closeDatasource() {
        if (dataSource instanceof AutoCloseable closeable) {
            try {
                closeable.close();
            } catch (Exception e) {
                log.warn("Error closing registry datasource", e);
            }
        }
    }

    @Override
    public JSONObject fetchData(Map<String, Object> identityDetails) throws DataProviderExchangeException {
        // 1. Resolve the query from the token scope (scope claim may be space-delimited).
        String rawScope = asString(identityDetails.get("scope"));
        if (rawScope == null || rawScope.isBlank()) {
            throw new DataProviderExchangeException("INVALID_SCOPE");
        }
        String matchedScope = null;
        String query = null;
        for (String s : rawScope.trim().split("\\s+")) {
            if (scopeQueryMapping.containsKey(s)) {
                matchedScope = s;
                query = scopeQueryMapping.get(s);
                break;
            }
        }
        if (query == null) {
            log.error("No scope-query-mapping entry for any scope in '{}'", rawScope);
            throw new DataProviderExchangeException("NO_QUERY_FOR_SCOPE");
        }

        // 2. Bind each SQL named parameter from the configured token claim.
        MapSqlParameterSource params = new MapSqlParameterSource();
        for (Map.Entry<String, String> e : paramClaimMapping.entrySet()) {
            String paramName = e.getKey();
            String claimName = e.getValue();
            Object value = identityDetails.get(claimName);
            if (value == null) {
                log.error("Token claim '{}' (for SQL param ':{}') is missing/null", claimName, paramName);
                throw new DataProviderExchangeException("MISSING_IDENTIFIER_CLAIM");
            }
            params.addValue(paramName, value);
        }

        // 3. Query the Registry DB; map the single matching row to claims.
        try {
            List<Map<String, Object>> rows = jdbc.queryForList(query, params);
            if (rows.isEmpty()) {
                log.info("No active Registry record for scope '{}' — treating as not eligible", matchedScope);
                throw new DataProviderExchangeException("ERROR_FETCHING_DATA_RECORD_FROM_TABLE");
            }
            if (rows.size() > 1) {
                log.warn("Scope '{}' query returned {} rows; using the first. "
                        + "Ensure a 1:1 mapping or add LIMIT 1 to the query.", matchedScope, rows.size());
            }
            JSONObject result = new JSONObject();
            for (Map.Entry<String, Object> col : rows.get(0).entrySet()) {
                result.put(col.getKey(), col.getValue() == null ? JSONObject.NULL : col.getValue());
            }
            log.info("Fetched Registry claims for scope '{}' ({} fields)", matchedScope, result.length());
            return result;
        } catch (DataProviderExchangeException dpe) {
            throw dpe;
        } catch (Exception ex) {
            log.error("Error querying Registry DB for scope '{}'", matchedScope, ex);
            throw new DataProviderExchangeException("ERROR_FETCHING_DATA_RECORD_FROM_TABLE");
        }
    }

    private static String asString(Object v) {
        return v == null ? null : String.valueOf(v);
    }
}
