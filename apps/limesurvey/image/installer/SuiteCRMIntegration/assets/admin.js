/**
 * SuiteCRM Integration Admin JavaScript
 * 
 * Handles AJAX interactions for the plugin admin interface.
 * 
 * @version 2.0.0
 */
(function($) {
    'use strict';

    var SuiteCRMAdmin = {
        baseUrl: null,
        
        init: function() {
            this.baseUrl = $('meta[name="baseUrl"]').attr('content') || '';
            this.bindEvents();
        },
        
        bindEvents: function() {
            // Test connection button
            $(document).on('click', '.suitecrm-test-connection', this.testConnection.bind(this));
            
            // Refresh cache button
            $(document).on('click', '.suitecrm-refresh-cache', this.refreshCache.bind(this));
            
            // View sync logs button
            $(document).on('click', '.suitecrm-view-logs', this.viewSyncLogs.bind(this));
        },
        
        /**
         * Make AJAX request to plugin endpoint
         */
        ajaxRequest: function(functionName, data, callback) {
            var url = this.baseUrl + '/index.php/plugins/direct';
            
            $.ajax({
                url: url,
                type: 'GET',
                data: $.extend({
                    plugin: 'SuiteCRMIntegration',
                    function: functionName
                }, data || {}),
                dataType: 'json',
                success: function(response) {
                    callback(null, response);
                },
                error: function(xhr, status, error) {
                    var errorMsg = 'Request failed';
                    try {
                        var response = JSON.parse(xhr.responseText);
                        errorMsg = response.error || errorMsg;
                    } catch (e) {
                        errorMsg = error || status;
                    }
                    callback(errorMsg, null);
                }
            });
        },
        
        /**
         * Test connection to SuiteCRM
         */
        testConnection: function(e) {
            e.preventDefault();
            var $btn = $(e.currentTarget);
            var $result = $btn.siblings('.connection-result');
            
            $btn.prop('disabled', true).text('Testing...');
            
            this.ajaxRequest('actionTestConnection', {}, function(err, response) {
                $btn.prop('disabled', false).text('Test Connection');
                
                if (err) {
                    $result.html('<span class="text-danger"><i class="ri-close-circle-line"></i> ' + err + '</span>');
                    return;
                }
                
                if (response.success) {
                    $result.html('<span class="text-success"><i class="ri-check-line"></i> Connected! Found ' + 
                        (response.modules_count || 0) + ' modules.</span>');
                } else {
                    $result.html('<span class="text-danger"><i class="ri-close-circle-line"></i> ' + 
                        (response.message || 'Connection failed') + '</span>');
                }
            });
        },
        
        /**
         * Refresh field cache
         */
        refreshCache: function(e) {
            e.preventDefault();
            var $btn = $(e.currentTarget);
            var $result = $btn.siblings('.cache-result');
            
            $btn.prop('disabled', true).text('Refreshing...');
            
            this.ajaxRequest('actionRefreshCache', {}, function(err, response) {
                $btn.prop('disabled', false).text('Refresh Field Cache');
                
                if (err) {
                    $result.html('<span class="text-danger"><i class="ri-close-circle-line"></i> ' + err + '</span>');
                    return;
                }
                
                if (response.success) {
                    var statusHtml = '<span class="text-success"><i class="ri-check-line"></i> Cache refreshed!</span><ul>';
                    $.each(response.status || {}, function(module, status) {
                        if (status.success) {
                            statusHtml += '<li>' + module + ': ' + status.field_count + ' fields</li>';
                        } else {
                            statusHtml += '<li class="text-danger">' + module + ': ' + status.error + '</li>';
                        }
                    });
                    statusHtml += '</ul>';
                    $result.html(statusHtml);
                } else {
                    $result.html('<span class="text-danger"><i class="ri-close-circle-line"></i> ' + 
                        (response.error || 'Refresh failed') + '</span>');
                }
            });
        },
        
        /**
         * View sync logs for a survey
         */
        viewSyncLogs: function(e) {
            e.preventDefault();
            var $btn = $(e.currentTarget);
            var surveyId = $btn.data('survey-id');
            var $container = $btn.siblings('.sync-logs-container');
            
            if (!surveyId) {
                alert('Survey ID not found');
                return;
            }
            
            $btn.prop('disabled', true).text('Loading...');
            
            this.ajaxRequest('actionGetSyncLogs', { surveyId: surveyId, limit: 20 }, function(err, response) {
                $btn.prop('disabled', false).text('View Sync Logs');
                
                if (err) {
                    $container.html('<div class="alert alert-danger">' + err + '</div>');
                    return;
                }
                
                var html = '<div class="sync-logs-panel">';
                html += '<h5>Sync Statistics</h5>';
                html += '<p>Total: ' + (response.stats.total || 0) + 
                    ' | Success: ' + (response.stats.success || 0) + 
                    ' | Failed: ' + (response.stats.failed || 0) + '</p>';
                
                if (response.logs && response.logs.length > 0) {
                    html += '<table class="table table-sm"><thead><tr>' +
                        '<th>Time</th><th>Module</th><th>Status</th><th>CRM ID</th><th>Error</th>' +
                        '</tr></thead><tbody>';
                    
                    $.each(response.logs, function(i, log) {
                        var statusClass = log.sync_status === 'success' ? 'success' : 'danger';
                        html += '<tr class="table-' + statusClass + '">' +
                            '<td>' + log.synced_at + '</td>' +
                            '<td>' + log.crm_module + '</td>' +
                            '<td>' + log.sync_status + '</td>' +
                            '<td>' + (log.crm_record_id || '-') + '</td>' +
                            '<td>' + (log.error_message || '-') + '</td>' +
                            '</tr>';
                    });
                    html += '</tbody></table>';
                } else {
                    html += '<p class="text-muted">No sync logs found.</p>';
                }
                html += '</div>';
                
                $container.html(html);
            });
        }
    };

    // Initialize on document ready
    $(document).ready(function() {
        SuiteCRMAdmin.init();
    });

})(jQuery);

