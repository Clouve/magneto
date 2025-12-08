/**
 * SuiteCRM Integration Question Editor JavaScript
 *
 * Provides a visual UI for one-to-many field mappings with table-first selection.
 * Mappings are grouped by module/table for better organization.
 * Also formats JSON mappings for human-readable display in view mode.
 *
 * @version 2.6.0
 */
(function($) {
    'use strict';

    var SuiteCRMQuestionEditor = {
        baseUrl: null,
        fieldsCache: {},
        fieldOptionsCache: null,
        transformRulesCache: null,
        modulesCache: null,
        initialized: false,

        init: function() {
            if (this.initialized) return;
            this.initialized = true;

            this.baseUrl = $('meta[name="baseUrl"]').attr('content') || '';
            this.bindEvents();

            // Format any JSON displays in view mode (question summary)
            this.formatViewModeDisplays();

            // Load both field options and transform rules, then initialize UI
            var self = this;
            var fieldsLoaded = false;
            var rulesLoaded = false;

            var tryInitialize = function() {
                if (fieldsLoaded && rulesLoaded) {
                    self.initializeAllMappingUIs();
                }
            };

            this.loadFieldOptions(function() {
                fieldsLoaded = true;
                tryInitialize();
            });

            this.loadTransformRules(function() {
                rulesLoaded = true;
                tryInitialize();
            });
        },

        /**
         * Format JSON mappings in view mode (question summary) for human-readable display
         */
        formatViewModeDisplays: function() {
            var self = this;

            // Find rows in the question summary that contain "CRM Field Mappings"
            $('.summary-table .row, .question-summary .row, div.row').each(function() {
                var $row = $(this);
                var $labelCol = $row.find('.col-2 strong, .col-3 strong, td:first-child strong');

                // Check if this row contains our attribute label
                var labelText = $labelCol.text().trim();
                if (labelText.indexOf('CRM Field Mappings') === -1) {
                    return;
                }

                // Find the value column
                var $valueCol = $row.find('.col-10, .col-9, td:last-child');
                if (!$valueCol.length) return;

                var rawValue = $valueCol.text().trim();

                // Check if it looks like JSON
                if (!rawValue.startsWith('[') || !rawValue.endsWith(']')) {
                    return;
                }

                // Parse and format the JSON
                var formattedHtml = self.formatMappingsForDisplay(rawValue);
                if (formattedHtml) {
                    $valueCol.html(formattedHtml);
                }
            });
        },

        /**
         * Parse JSON mappings and return human-readable HTML
         * @param {string} jsonString - The raw JSON string
         * @returns {string|null} - Formatted HTML or null if parsing fails
         */
        formatMappingsForDisplay: function(jsonString) {
            var self = this;

            try {
                var mappings = JSON.parse(jsonString);

                if (!Array.isArray(mappings)) {
                    return null;
                }

                // Handle empty array
                if (mappings.length === 0) {
                    return '<span class="suitecrm-no-mappings">No mappings configured</span>';
                }

                // Group mappings by module
                var moduleGroups = {};
                mappings.forEach(function(mapping) {
                    var module = mapping.module || mapping.crm_module || 'Unknown';
                    if (!moduleGroups[module]) {
                        moduleGroups[module] = [];
                    }
                    moduleGroups[module].push(mapping);
                });

                // Build formatted HTML
                var html = '<div class="suitecrm-mappings-display">';

                $.each(moduleGroups, function(module, moduleMappings) {
                    html += '<div class="suitecrm-display-group">';
                    html += '<span class="suitecrm-display-module">' + self.escapeHtml(module) + '</span>';
                    html += '<span class="suitecrm-display-fields">';

                    var fieldParts = [];
                    moduleMappings.forEach(function(mapping) {
                        var field = mapping.field || mapping.crm_field_name || 'unknown';
                        var transform = mapping.transformRule || mapping.transform_rule || '';

                        var fieldText = self.escapeHtml(field);
                        if (transform && transform !== 'none') {
                            // Check if it's an auto-generate rule
                            var isAutoGenerate = transform.indexOf('auto_') === 0;
                            var transformClass = isAutoGenerate ? 'suitecrm-display-autogen' : 'suitecrm-display-transform';
                            var transformLabel = self.getTransformLabel(transform);
                            fieldText += ' <span class="' + transformClass + '">(' + self.escapeHtml(transformLabel) + ')</span>';
                        }
                        fieldParts.push(fieldText);
                    });

                    html += fieldParts.join(', ');
                    html += '</span>';
                    html += '</div>';
                });

                html += '</div>';
                return html;

            } catch (e) {
                console.error('Error parsing CRM mappings JSON:', e);
                return null;
            }
        },

        /**
         * Escape HTML special characters
         */
        escapeHtml: function(str) {
            if (!str) return '';
            return String(str)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#039;');
        },

        /**
         * Get human-readable label for a transform rule
         */
        getTransformLabel: function(rule) {
            var labels = {
                'split_first': 'first word',
                'split_last': 'last word',
                'split_middle': 'middle words',
                'uppercase': 'uppercase',
                'lowercase': 'lowercase',
                'trim': 'trim',
                'email_domain': 'email domain',
                'email_local': 'email local',
                'auto_uuid': 'auto: UUID',
                'auto_number': 'auto: number',
                'auto_date': 'auto: date',
                'auto_datetime': 'auto: datetime',
                'auto_timestamp': 'auto: timestamp',
                'auto_survey_ref': 'auto: survey ref'
            };
            return labels[rule] || rule;
        },

        /**
         * Load all CRM field options from the server
         */
        loadFieldOptions: function(callback) {
            var self = this;
            var url = this.baseUrl + '/index.php/plugins/direct';

            $.ajax({
                url: url,
                type: 'GET',
                data: {
                    plugin: 'SuiteCRMIntegration',
                    function: 'actionGetAllFields'
                },
                dataType: 'json',
                success: function(response) {
                    if (response.fields) {
                        self.fieldOptionsCache = response.fields;
                        self.modulesCache = response.modules || Object.keys(response.fields);
                    }
                    if (typeof callback === 'function') callback();
                },
                error: function() {
                    console.warn('Could not load CRM fields from server');
                    if (typeof callback === 'function') callback();
                }
            });
        },

        /**
         * Load available transformation rules
         */
        loadTransformRules: function(callback) {
            var self = this;

            if (this.transformRulesCache) {
                if (callback) callback();
                return;
            }

            var url = this.baseUrl + '/index.php/plugins/direct';

            $.ajax({
                url: url,
                type: 'GET',
                data: {
                    plugin: 'SuiteCRMIntegration',
                    function: 'actionGetTransformRules'
                },
                dataType: 'json',
                success: function(response) {
                    if (response.rules) {
                        self.transformRulesCache = response.rules;
                    } else {
                        self.setDefaultTransformRules();
                    }
                    if (callback) callback();
                },
                error: function() {
                    self.setDefaultTransformRules();
                    if (callback) callback();
                }
            });
        },

        setDefaultTransformRules: function() {
            this.transformRulesCache = {
                'none': 'No transformation',
                'split_first': 'First word (e.g., "John Doe" → "John")',
                'split_last': 'Last word (e.g., "John Doe" → "Doe")',
                'split_middle': 'Middle words',
                'uppercase': 'UPPERCASE',
                'lowercase': 'lowercase',
                'trim': 'Trim whitespace',
                // Auto-generation rules
                'auto_uuid': '⚡ Auto-generate: Unique ID (UUID)',
                'auto_number': '⚡ Auto-generate: Sequential number',
                'auto_date': '⚡ Auto-generate: Current date',
                'auto_datetime': '⚡ Auto-generate: Current date/time',
                'auto_timestamp': '⚡ Auto-generate: Unix timestamp',
                'auto_survey_ref': '⚡ Auto-generate: Survey reference'
            };
        },

        /**
         * Bind event handlers (called once)
         */
        bindEvents: function() {
            $(document).off('.suitecrmMapping');
            $(document).on('click.suitecrmMapping', '.suitecrm-add-mapping-btn', this.onAddMapping.bind(this));
            $(document).on('click.suitecrmMapping', '.suitecrm-remove-mapping-btn', this.onRemoveMapping.bind(this));
            $(document).on('change.suitecrmMapping', '.suitecrm-field-row select', this.onMappingChange.bind(this));
        },

        /**
         * Initialize mapping UI for all JSON fields on the page
         */
        initializeAllMappingUIs: function() {
            var self = this;
            $('input[name*="suitecrm_mappings_json"], textarea[name*="suitecrm_mappings_json"]').each(function() {
                self.initializeMappingUI($(this));
            });
        },

        /**
         * Build table selector options HTML
         */
        buildTableOptionsHtml: function() {
            var html = '<option value="">-- Select CRM Module --</option>';

            if (this.modulesCache && this.modulesCache.length > 0) {
                this.modulesCache.forEach(function(module) {
                    html += '<option value="' + module + '">' + module + '</option>';
                });
            } else if (this.fieldOptionsCache) {
                $.each(this.fieldOptionsCache, function(module) {
                    html += '<option value="' + module + '">' + module + '</option>';
                });
            }

            return html;
        },

        /**
         * Initialize the visual mapping UI for a single JSON field
         */
        initializeMappingUI: function($jsonField) {
            var self = this;

            var $formGroup = $jsonField.closest('.mb-3, .form-group');
            if (!$formGroup.length) {
                $formGroup = $jsonField.parent();
            }

            if ($formGroup.find('.suitecrm-mapping-container').length) {
                return;
            }

            $jsonField.hide();

            // Create container with controls (LimeSurvey already provides the attribute label)
            var $container = $(
                '<div class="suitecrm-mapping-container">' +
                '  <div class="suitecrm-mapping-header">' +
                '    <div class="suitecrm-add-mapping-controls">' +
                '      <span class="suitecrm-controls-label">CRM Module:</span>' +
                '      <select class="form-select form-select-sm suitecrm-table-select">' +
                         self.buildTableOptionsHtml() +
                '      </select>' +
                '      <button type="button" class="btn btn-sm btn-success suitecrm-add-mapping-btn" title="Add field mapping for selected table">' +
                '        <span>+</span>' +
                '      </button>' +
                '    </div>' +
                '  </div>' +
                '  <div class="suitecrm-module-groups"></div>' +
                '  <div class="suitecrm-mapping-empty">' +
                '    No field mappings configured. Select a module and click "+" to add.' +
                '  </div>' +
                '</div>'
            );

            $container.data('jsonField', $jsonField);
            $formGroup.append($container);

            // Parse existing mappings and group by module
            var existingMappings = [];
            try {
                var jsonVal = $jsonField.val();
                if (jsonVal && jsonVal !== '[]') {
                    existingMappings = JSON.parse(jsonVal);
                }
            } catch (e) {
                console.error('Error parsing existing mappings:', e);
            }

            var $groups = $container.find('.suitecrm-module-groups');
            var $empty = $container.find('.suitecrm-mapping-empty');

            if (Array.isArray(existingMappings) && existingMappings.length > 0) {
                // Group mappings by module
                var moduleGroups = {};
                existingMappings.forEach(function(mapping) {
                    var module = mapping.module || mapping.crm_module;
                    if (!moduleGroups[module]) {
                        moduleGroups[module] = [];
                    }
                    moduleGroups[module].push(mapping);
                });

                // Create group containers for each module
                $.each(moduleGroups, function(module, mappings) {
                    var $group = self.createModuleGroup($groups, module);
                    mappings.forEach(function(mapping) {
                        self.addFieldRow($group.find('.suitecrm-module-fields'), module, mapping);
                    });
                });

                $empty.hide();
            } else {
                $empty.show();
            }
        },

        /**
         * Create a module group container
         */
        createModuleGroup: function($groupsContainer, module) {
            var $group = $(
                '<div class="suitecrm-module-group" data-module="' + module + '">' +
                '  <div class="suitecrm-module-header">' +
                '    <span class="suitecrm-module-label">' + module + '</span>' +
                '  </div>' +
                '  <div class="suitecrm-module-fields"></div>' +
                '</div>'
            );

            $groupsContainer.append($group);
            return $group;
        },

        /**
         * Get or create a module group
         */
        getOrCreateModuleGroup: function($container, module) {
            var $groups = $container.find('.suitecrm-module-groups');
            var $existingGroup = $groups.find('.suitecrm-module-group[data-module="' + module + '"]');

            if ($existingGroup.length) {
                return $existingGroup;
            }

            return this.createModuleGroup($groups, module);
        },

        /**
         * Build the CRM field options HTML for a specific module/table
         */
        buildFieldOptionsHtml: function(module) {
            var html = '<option value="">-- Select CRM Field --</option>';

            if (!module || !this.fieldOptionsCache || !this.fieldOptionsCache[module]) {
                return html;
            }

            var fields = this.fieldOptionsCache[module];
            $.each(fields, function(fieldName, fieldDef) {
                var label = fieldDef.label || fieldName;
                var required = fieldDef.required ? ' *' : '';
                var value = JSON.stringify({module: module, field: fieldName});
                html += '<option value=\'' + value.replace(/'/g, '&#39;') + '\'>' +
                        label + required + '</option>';
            });

            return html;
        },

        /**
         * Build the transform rule options HTML
         */
        buildTransformOptionsHtml: function() {
            var html = '<option value="">None (use value as-is)</option>';

            if (this.transformRulesCache) {
                $.each(this.transformRulesCache, function(key, label) {
                    if (key !== 'none') {
                        html += '<option value="' + key + '">' + label + '</option>';
                    }
                });
            }

            return html;
        },

        /**
         * Add a field row within a module group
         */
        addFieldRow: function($fieldsContainer, module, existingMapping) {
            var rowId = 'field-' + Date.now() + '-' + Math.random().toString(36).substring(2, 11);

            var $row = $(
                '<div class="suitecrm-field-row" data-row-id="' + rowId + '" data-module="' + module + '">' +
                '  <div class="suitecrm-field-col suitecrm-field-col-field">' +
                '    <label class="suitecrm-field-label">CRM Field</label>' +
                '    <select class="form-select form-select-sm suitecrm-field-select">' +
                       this.buildFieldOptionsHtml(module) +
                '    </select>' +
                '  </div>' +
                '  <div class="suitecrm-field-col suitecrm-field-col-transform">' +
                '    <label class="suitecrm-field-label">Value Transform</label>' +
                '    <select class="form-select form-select-sm suitecrm-transform-select">' +
                       this.buildTransformOptionsHtml() +
                '    </select>' +
                '  </div>' +
                '  <div class="suitecrm-field-col suitecrm-field-col-action">' +
                '    <button type="button" class="btn btn-sm btn-outline-danger suitecrm-remove-mapping-btn" title="Remove">' +
                '      <span>−</span>' +
                '    </button>' +
                '  </div>' +
                '</div>'
            );

            if (existingMapping) {
                var fieldValue = JSON.stringify({
                    module: existingMapping.module || existingMapping.crm_module,
                    field: existingMapping.field || existingMapping.crm_field_name
                });
                $row.find('.suitecrm-field-select').val(fieldValue);
                $row.find('.suitecrm-transform-select').val(
                    existingMapping.transformRule || existingMapping.transform_rule || ''
                );
            }

            $fieldsContainer.append($row);
        },

        /**
         * Handle Add Mapping button click
         */
        onAddMapping: function(e) {
            e.preventDefault();
            e.stopPropagation();

            var $button = $(e.currentTarget);
            var $container = $button.closest('.suitecrm-mapping-container');
            var $tableSelect = $container.find('.suitecrm-table-select');
            var selectedTable = $tableSelect.val();

            if (!selectedTable) {
                $tableSelect.addClass('is-invalid');
                setTimeout(function() {
                    $tableSelect.removeClass('is-invalid');
                }, 1500);
                return;
            }

            // Get or create the module group
            var $group = this.getOrCreateModuleGroup($container, selectedTable);
            var $fields = $group.find('.suitecrm-module-fields');

            this.addFieldRow($fields, selectedTable, null);
            $container.find('.suitecrm-mapping-empty').hide();
            this.serializeMappings($container);
        },

        /**
         * Handle Remove Mapping button click
         */
        onRemoveMapping: function(e) {
            e.preventDefault();
            e.stopPropagation();

            var $button = $(e.currentTarget);
            var $row = $button.closest('.suitecrm-field-row');
            var $group = $row.closest('.suitecrm-module-group');
            var $container = $button.closest('.suitecrm-mapping-container');

            $row.remove();

            // Remove the group if it has no more fields
            if ($group.find('.suitecrm-field-row').length === 0) {
                $group.remove();
            }

            // Show empty message if no groups left
            if ($container.find('.suitecrm-module-group').length === 0) {
                $container.find('.suitecrm-mapping-empty').show();
            }

            this.serializeMappings($container);
        },

        /**
         * Handle mapping field/transform changes
         */
        onMappingChange: function(e) {
            var $container = $(e.currentTarget).closest('.suitecrm-mapping-container');
            this.serializeMappings($container);
        },

        /**
         * Serialize all mapping rows to JSON and store in hidden field
         */
        serializeMappings: function($container) {
            var $jsonField = $container.data('jsonField');
            if (!$jsonField || !$jsonField.length) {
                return;
            }

            var mappings = [];

            $container.find('.suitecrm-field-row').each(function() {
                var $row = $(this);
                var fieldValue = $row.find('.suitecrm-field-select').val();
                var transformValue = $row.find('.suitecrm-transform-select').val();

                if (fieldValue) {
                    try {
                        var fieldData = JSON.parse(fieldValue);
                        mappings.push({
                            module: fieldData.module,
                            field: fieldData.field,
                            transformRule: transformValue || ''
                        });
                    } catch (e) {
                        console.error('Error parsing field value:', e);
                    }
                }
            });

            $jsonField.val(JSON.stringify(mappings));
        }
    };

    $(document).ready(function() {
        SuiteCRMQuestionEditor.init();
    });

    $(document).on('pjax:complete ajaxComplete', function() {
        setTimeout(function() {
            SuiteCRMQuestionEditor.initializeAllMappingUIs();
        }, 100);
    });

})(jQuery);

