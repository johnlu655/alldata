local pl_pretty = require("pl.pretty").write
local pl_keys = require("pl.tablex").keys
local nkeys = require("table.nkeys")
local table_isarray = require("table.isarray")
local utils = require("kong.tools.utils")


local type         = type
local null         = ngx.null
local log          = ngx.log
local WARN         = ngx.WARN
local error        = error
local upper        = string.upper
local fmt          = string.format
local pairs        = pairs
local ipairs       = ipairs
local tostring     = tostring
local setmetatable = setmetatable
local getmetatable = getmetatable
local concat       = table.concat
local sort         = table.sort
local insert       = table.insert


local sorted_keys = function(tbl)
  local keys = pl_keys(tbl)
  sort(keys)
  return keys
end


-- error codes


local ERRORS              = {
  INVALID_PRIMARY_KEY     = 1,
  SCHEMA_VIOLATION        = 2,
  PRIMARY_KEY_VIOLATION   = 3,  -- primary key already exists (HTTP 400)
  FOREIGN_KEY_VIOLATION   = 4,  -- foreign entity does not exist (HTTP 400)
  UNIQUE_VIOLATION        = 5,  -- unique key already exists (HTTP 409)
  NOT_FOUND               = 6,  -- WHERE clause leads nowhere (HTTP 404)
  INVALID_OFFSET          = 7,  -- page(size, offset) is invalid
  DATABASE_ERROR          = 8,  -- connection refused or DB error (HTTP 500)
  INVALID_SIZE            = 9,  -- page(size, offset) is invalid
  INVALID_UNIQUE          = 10, -- unique field value is invalid
  INVALID_OPTIONS         = 11, -- invalid options given
  OPERATION_UNSUPPORTED   = 12, -- operation is not supported with this strategy
  FOREIGN_KEYS_UNRESOLVED = 13, -- foreign key(s) could not be resolved
  DECLARATIVE_CONFIG      = 14, -- error parsing declarative configuration
  TRANSFORMATION_ERROR    = 15, -- error with dao transformations
  INVALID_FOREIGN_KEY     = 16, -- foreign key is valid for matching a row
  INVALID_WORKSPACE       = 17, -- strategy reports a workspace error
  INVALID_UNIQUE_GLOBAL   = 18, -- unique field value is invalid for global query
}


-- error codes messages


local ERRORS_NAMES                 = {
  [ERRORS.INVALID_PRIMARY_KEY]     = "invalid primary key",
  [ERRORS.SCHEMA_VIOLATION]        = "schema violation",
  [ERRORS.PRIMARY_KEY_VIOLATION]   = "primary key violation",
  [ERRORS.FOREIGN_KEY_VIOLATION]   = "foreign key violation",
  [ERRORS.UNIQUE_VIOLATION]        = "unique constraint violation",
  [ERRORS.NOT_FOUND]               = "not found",
  [ERRORS.INVALID_OFFSET]          = "invalid offset",
  [ERRORS.DATABASE_ERROR]          = "database error",
  [ERRORS.INVALID_SIZE]            = "invalid size",
  [ERRORS.INVALID_UNIQUE]          = "invalid unique %s",
  [ERRORS.INVALID_OPTIONS]         = "invalid options",
  [ERRORS.OPERATION_UNSUPPORTED]   = "operation unsupported",
  [ERRORS.FOREIGN_KEYS_UNRESOLVED] = "foreign keys unresolved",
  [ERRORS.DECLARATIVE_CONFIG]      = "invalid declarative configuration",
  [ERRORS.TRANSFORMATION_ERROR]    = "transformation error",
  [ERRORS.INVALID_FOREIGN_KEY]     = "invalid foreign key",
  [ERRORS.INVALID_WORKSPACE]       = "invalid workspace",
  [ERRORS.INVALID_UNIQUE_GLOBAL]   = "invalid global query",
}


-- err_t metatable definition


local _err_mt = {
  __tostring = function(err_t)
    local message = err_t.message
    if message == nil or message == null then
       message = err_t.name
    end

    if err_t.strategy then
      return fmt("[%s] %s", err_t.strategy, message)
    end

    return message
  end,

  __concat = function(a, b)
    return tostring(a) .. tostring(b)
  end,
}


-- error module


local _M = {
  codes  = ERRORS,
  names  = ERRORS_NAMES,
}


local function new_err_t(self, code, message, errors, name)
  if type(message) == "table" and getmetatable(message) == _err_mt then
    return message
  end

  if not code then
    error("missing code")
  end

  if not ERRORS_NAMES[code] then
    error("unknown error code: " .. tostring(code))
  end

  if message and type(message) ~= "string" then
    error("message must be a string or nil")
  end

  if errors and type(errors) ~= "table" then
    error("errors must be a table or nil")
  end

  local err_t = {
    code      = code,
    name      = name or ERRORS_NAMES[code],
    message   = message or null,
    strategy  = self.strategy,
  }

  if errors then
    local fields = {}

    for k, v in pairs(errors) do
      fields[k] = v
    end

    if code == ERRORS.INVALID_OPTIONS then
      err_t.options = fields
    else
      err_t.fields = fields
    end
  end

  return setmetatable(err_t, _err_mt)
end


function _M.__index(self, k)
  if ERRORS[k] then
    return ERRORS[k]
  end

  if _M[k] then
    return _M[k]
  end

  local upper_key = upper(k)
  if ERRORS[upper_key] then
    local f = function()
      return new_err_t(self, ERRORS[upper_key])
    end

    self[k] = f

    return f
  end
end


function _M.new(strategy)
  local self = {
    strategy = strategy,
  }

  return setmetatable(self, _M)
end


function _M:invalid_primary_key(primary_key)
  if type(primary_key) ~= "table" then
    error("primary_key must be a table", 2)
  end

  local message = fmt("invalid primary key: '%s'", pl_pretty(primary_key, ""))

  return new_err_t(self, ERRORS.INVALID_PRIMARY_KEY, message, primary_key)
end


function _M:invalid_foreign_key(foreign_key)
  if type(foreign_key) ~= "table" then
    error("foreign_key must be a table", 2)
  end

  local message = fmt("invalid foreign key: '%s'", pl_pretty(foreign_key, ""))

  return new_err_t(self, ERRORS.INVALID_FOREIGN_KEY, message, foreign_key)
end


function _M:schema_violation(errors)
  if type(errors) ~= "table" then
    error("errors must be a table", 2)
  end

  local buf = {}
  local len = 0

  if errors["@entity"] then
    for _, err in pairs(errors["@entity"]) do
      len = len + 1
      buf[len] = err
    end
  end

  for _, field_name in ipairs(sorted_keys(errors)) do
    if field_name ~= "@entity" then
      local field_errors = errors[field_name]
      if type(field_errors) == "table" then
        for _, sub_field in ipairs(sorted_keys(field_errors)) do
          len = len + 1
          local value = field_errors[sub_field]
          if type(value) == "table" then
            value = pl_pretty(value)
          end
          buf[len] = fmt("%s.%s: %s", field_name, sub_field, value)
        end

      else
        len = len + 1
        buf[len] = fmt("%s: %s", field_name, field_errors)
      end
    end
  end

  local message

  if len == 1 then
    message = fmt("schema violation (%s)", buf[1])

  else
    message = fmt("%d schema violations (%s)",
                  len, concat(buf, "; "))
  end

  return new_err_t(self, ERRORS.SCHEMA_VIOLATION, message, errors)
end


function _M:primary_key_violation(primary_key)
  if type(primary_key) ~= "table" then
    error("primary_key must be a table", 2)
  end

  local message = fmt("primary key violation on key '%s'",
                      pl_pretty(primary_key, ""))

  return new_err_t(self, ERRORS.PRIMARY_KEY_VIOLATION, message, primary_key)
end


function _M:foreign_key_violation_invalid_reference(foreign_key,
                                                    foreign_key_field_name,
                                                    parent_name)
  if type(foreign_key) ~= "table" then
    error("foreign_key must be a table", 2)
  end

  if type(foreign_key_field_name) ~= "string" then
    error("foreign_key_field_name must be a string", 2)
  end

  if type(parent_name) ~= "string" then
    error("parent_name must be a string", 2)
  end

  local message = fmt("the foreign key '%s' does not reference an existing '%s' entity.",
                      pl_pretty(foreign_key, ""), parent_name)

  return new_err_t(self, ERRORS.FOREIGN_KEY_VIOLATION, message, {
    [foreign_key_field_name] = foreign_key
  })
end


function _M:foreign_key_violation_restricted(parent_name, child_name)
  if type(parent_name) ~= "string" then
    error("parent_name must be a string", 2)
  end

  if type(child_name) ~= "string" then
    error("child_name must be a string", 2)
  end

  local message = fmt("an existing '%s' entity references this '%s' entity",
                      child_name, parent_name)

  return new_err_t(self, ERRORS.FOREIGN_KEY_VIOLATION, message, {
    ["@referenced_by"] = child_name
  })
end


function _M:foreign_keys_unresolved(errors)
  if type(errors) ~= "table" then
    error("errors must be a table", 2)
  end

  local buf = {}
  local len = 0

  for _, field_name in ipairs(sorted_keys(errors)) do
    local field_errors = errors[field_name]
    if type(field_errors) == "table" then
      for _, sub_field in ipairs(sorted_keys(field_errors)) do
        len = len + 1
        local value = field_errors[sub_field]
        if type(value) == "table" then
          value = fmt("the foreign key cannot be resolved with '%s' for an existing '%s' entity",
                      pl_pretty({ [value.name] = value.value }, ""), value.parent)
        end
        field_errors[sub_field] = value
        buf[len] = fmt("%s.%s: %s", field_name, sub_field, value)
      end

    else
      len = len + 1
      buf[len] = fmt("%s: %s", field_name, field_errors)
    end
  end

  local message

  if len == 1 then
    message = fmt("foreign key unresolved (%s)", buf[1])

  else
    message = fmt("%d foreign keys unresolved (%s)",
      len, concat(buf, "; "))
  end

  return new_err_t(self, ERRORS.FOREIGN_KEYS_UNRESOLVED, message, errors)
end


function _M:unique_violation(unique_key)
  if type(unique_key) ~= "table" then
    error("unique_key must be a table", 2)
  end

  local message = fmt("UNIQUE violation detected on '%s'",
                      pl_pretty(unique_key, ""):gsub("\"userdata: NULL\"", "null"))

  return new_err_t(self, ERRORS.UNIQUE_VIOLATION, message, unique_key)
end


function _M:not_found(primary_key)
  if type(primary_key) ~= "table" then
    error("primary_key must be a table", 2)
  end

  local message = fmt("could not find the entity with primary key '%s'",
                      pl_pretty(primary_key, ""))

  return new_err_t(self, ERRORS.NOT_FOUND, message, primary_key)
end


function _M:not_found_by_field(filter)
  if type(filter) ~= "table" then
    error("filter must be a table", 2)
  end

  local message = fmt("could not find the entity with '%s'",
                      pl_pretty(filter, ""))

  return new_err_t(self, ERRORS.NOT_FOUND, message, filter)
end


function _M:invalid_offset(offset, err)
  if type(offset) ~= "string" then
    error("offset must be a string", 2)
  end

  if type(err) ~= "string" then
    error("err must be a string", 2)
  end

  local message = fmt("'%s' is not a valid offset: %s", offset, err)

  return new_err_t(self, ERRORS.INVALID_OFFSET, message)
end


function _M:database_error(err)
  err = err or ERRORS_NAMES[ERRORS.DATABASE_ERROR]
  return new_err_t(self, ERRORS.DATABASE_ERROR, err)
end


function _M:transformation_error(err)
  err = err or ERRORS_NAMES[ERRORS.TRANSFORMATION_ERROR]
  return new_err_t(self, ERRORS.TRANSFORMATION_ERROR, err)
end


function _M:invalid_size(err)
  if type(err) ~= "string" then
    error("err must be a string", 2)
  end

  return new_err_t(self, ERRORS.INVALID_SIZE, err)
end


function _M:invalid_unique(name, err)
  if type(err) ~= "string" then
    error("err must be a string", 2)
  end

  return new_err_t(self, ERRORS.INVALID_UNIQUE, err, nil,
                   fmt(ERRORS_NAMES[ERRORS.INVALID_UNIQUE], name))
end


function _M:invalid_options(errors)
  if type(errors) ~= "table" then
    error("errors must be a table", 2)
  end

  local buf = {}
  local len = 0

  for _, option_name in ipairs(sorted_keys(errors)) do
    local option_errors = errors[option_name]
    if type(option_errors) == "table" then
      for _, sub_option in ipairs(sorted_keys(option_errors)) do
        len = len + 1
        buf[len] = fmt("%s.%s: %s", option_name, sub_option,
                       option_errors[sub_option])
      end

    else
      len = len + 1
      buf[len] = fmt("%s: %s", option_name, option_errors)
    end
  end

  local message

  if len == 1 then
    message = fmt("invalid option (%s)", buf[1])

  else
    message = fmt("%d option violations (%s)",
                  len, concat(buf, "; "))
  end

  return new_err_t(self, ERRORS.INVALID_OPTIONS, message, errors)
end


function _M:operation_unsupported(err)
  if type(err) ~= "string" then
    error("err must be a string", 2)
  end

  return new_err_t(self, ERRORS.OPERATION_UNSUPPORTED, err)
end


function _M:declarative_config(err_t)
  if type(err_t) ~= "table" then
    error("err_t must be a table", 2)
  end

  local message = fmt("declarative config is invalid: %s",
                      pl_pretty(err_t, ""))

  return new_err_t(self, ERRORS.DECLARATIVE_CONFIG, message, err_t)
end


function _M:invalid_workspace(ws_id)
  if type(ws_id) ~= "string" then
    error("ws_id must be a string", 2)
  end

  local message = fmt("invalid workspace '%s'", ws_id)

  return new_err_t(self, ERRORS.INVALID_WORKSPACE, message)
end


function _M:invalid_unique_global(name)
  if type(name) ~= "string" then
    error("name must be a string", 2)
  end

  return new_err_t(self, ERRORS.INVALID_UNIQUE_GLOBAL,
                   fmt("unique key %s is invalid for global query", name))
end


local flatten_errors
do
  local function singular(noun)
    if noun:sub(-1) == "s" then
      return noun:sub(1, -2)
    end
    return noun
  end


  local function join(ns, field)
    if type(ns) == "string" and ns ~= "" then
      return ns .. "." .. field
    end
    return field
  end

  local function is_array(v)
    return type(v) == "table" and table_isarray(v)
  end


  local each_foreign_field
  do
    ---@type table<string, { field:string, entity:string, reference:string }[]>
    local relationships

    -- for each known entity, build a table of other entities which may
    -- reference it via a foreign key relationship as well as any of its
    -- own foreign key relationships.
    local function build_relationships()
      relationships = setmetatable({}, {
        __index = function(self, k)
          local t = {}
          rawset(self, k, t)
          return t
        end,
      })

      for entity, dao in pairs(kong.db.daos) do
        for fname, field in dao.schema:each_field() do
          if field.type == "foreign" then
            insert(relationships[entity], {
              field     = fname,
              entity    = entity,
              reference = field.reference,
            })

            -- create a backref for entities that may be nested under their
            -- foreign key reference entity (one-to-many relationships)
            --
            -- example: services and routes
            --
            -- route.service = { type = "foreign", reference = "services" }
            --
            -- insert(relationships.services, {
            --    field     = "service",
            --    entity    = "routes",
            --    reference = "services",
            -- })
            --
            insert(relationships[field.reference], {
              field     = fname,
              entity    = entity,
              reference = field.reference,
            })
          end
        end
      end
    end

    local empty = function() end

    ---@param  entity_type   string
    ---@return fun():{ field:string, entity:string, reference:string }? iterator
    function each_foreign_field(entity_type)
      -- this module is require()-ed before the kong global is initialized, so
      -- the lookup table of relationships needs to be built lazily
      if not relationships then
        build_relationships()
      end

      local fields = relationships[entity_type]

      if not fields then
        return empty
      end

      local i = 0
      return function()
        i = i + 1
        return fields[i]
      end
    end
  end


  ---@param err       table|string
  ---@param flattened table
  local function add_entity_error(err, flattened)
    if type(err) == "table" then
      for _, message in ipairs(err) do
        add_entity_error(message, flattened)
      end

    else
      insert(flattened, {
        type = "entity",
        message = err,
      })
    end
  end


  ---@param field     string
  ---@param err       table|string
  ---@param flattened table
  local function add_field_error(field, err, flattened)
    if type(err) == "table" then
      for _, message in ipairs(err) do
        add_field_error(field, message, flattened)
      end

    else
      insert(flattened, {
        type = "field",
        field = field,
        message = err,
      })
    end
  end


  ---@param errs       table
  ---@param ns?        string
  ---@param flattened? table
  local function categorize_errors(errs, ns, flattened)
    flattened = flattened or {}

    for field, err in pairs(errs) do
      local errtype = type(err)

      if field == "@entity" then
        add_entity_error(err, flattened)

      elseif errtype == "string" then
        add_field_error(join(ns, field), err, flattened)

      elseif errtype == "table" then
        categorize_errors(err, join(ns, field), flattened)

      else
        log(WARN, "unknown error type: ", errtype, " at key: ", field)
      end
    end

    return flattened
  end


  ---@param name any
  ---@return string|nil
  local function validate_name(name)
    return (type(name) == "string"
            and name:len() > 0
            and name)
           or nil
  end


  ---@param id any
  ---@return string|nil
  local function validate_id(id)
    return (type(id) == "string"
            and utils.is_valid_uuid(id)
            and id)
           or nil
  end


  ---@param tags any
  ---@return string[]|nil
  local function validate_tags(tags)
    if type(tags) == "table" and is_array(tags) then
      for i = 1, #tags do
        if type(tags[i]) ~= "string" then
          return
        end
      end

      return tags
    end
  end


  --- Add foreign key references to child entities.
  ---
  ---@param entity             table
  ---@param field_name         string
  ---@param foreign_field_name string
  local function add_foreign_keys(entity, field_name, foreign_field_name)
    local foreign_id = validate_id(entity.id)
    if not foreign_id then
      return
    end

    local values = entity[field_name]
    if type(values) ~= "table" then
      return
    end

    local fk = { id = foreign_id }
    for i = 1, #values do
      values[i][foreign_field_name] = values[i][foreign_field_name] or fk
    end
  end


  ---@param  entity     table
  ---@param  field_name string
  ---@return any
  local function replace_with_foreign_key(entity, field_name)
    local value = entity[field_name]
    entity[field_name] = nil

    if type(value) == "table" and value.id then
      entity[field_name] = { id = value.id }
    end

    return value
  end


  ---@param entity_type string
  ---@param entity      table
  ---@param err_t       table
  ---@param flattened   table
  local function add_entity_errors(entity_type, entity, err_t, flattened)
    if type(err_t) ~= "table" or nkeys(err_t) == 0 then
      return
    end

    -- instead of a single entity, we have a collection
    if is_array(entity) then
      for i = 1, #entity do
        add_entity_errors(entity_type, entity[i], err_t[i], flattened)
      end
      return
    end

    -- promote errors for foreign key relationships up to the top level
    -- array of errors and recursively flatten any of their validation
    -- errors
    for ref in each_foreign_field(entity_type) do
      local field_name
      local field_value
      local field_entity_type

      -- owned one-to-one relationship (e.g. service->client_certificate)
      if ref.entity == entity_type then
        field_name = ref.field
        field_entity_type = ref.reference
        field_value = replace_with_foreign_key(entity, field_name)

      -- foreign one-to-many relationship (e.g. service->routes)
      else
        field_name = ref.entity
        field_entity_type = field_name
        field_value = entity[field_name]

        add_foreign_keys(entity, field_name, ref.field)
        entity[field_name] = nil
      end

      local field_err_t = err_t[field_name]
      err_t[field_name] = nil

      if field_value and field_err_t then
        add_entity_errors(field_entity_type, field_value, field_err_t, flattened)
      end
    end

    -- all of our errors were related to foreign relationships;
    -- nothing left to do
    if nkeys(err_t) == 0 then
      return
    end

    local entity_errors = categorize_errors(err_t)
    if #entity_errors > 0 then
      insert(flattened, {
        -- entity_id, entity_name, and entity_tags must be validated to ensure
        -- that the response is well-formed. They are also optional, so we will
        -- simply leave them out if they are invalid.
        --
        -- The nested entity object itself will retain the original, untouched
        -- values for these fields.
        entity_name   = validate_name(entity.name),
        entity_id     = validate_id(entity.id),
        entity_tags   = validate_tags(entity.tags),
        entity_type   = singular(entity_type),
        entity        = entity,
        errors        = entity_errors,
      })
    else
      log(WARN, "failed to categorize errors for ", entity_type,
                ", ", entity.name or entity.id)
    end
  end


  ---@param  err_t table
  ---@param  input table
  ---@return table
  function flatten_errors(input, err_t)
    local flattened = {}

    for entity_type, section_errors in pairs(err_t) do
      if type(section_errors) ~= "table" then
        log(WARN, "failed to resolve errors for ", entity_type)
        goto next_section
      end

      local entities = input[entity_type]

      if type(entities) ~= "table" then
        log(WARN, "failed to resolve errors for ", entity_type)
        goto next_section
      end

      for idx, errs in pairs(section_errors) do
        local entity = entities[idx]

        if type(entity) == "table" then
          add_entity_errors(entity_type, entity, errs, flattened)

        else
          log(WARN, "failed to resolve errors for ", entity_type, " at ",
                    "index '", idx, "'")
        end
      end

      ::next_section::
    end

    return flattened
  end
end


-- traverse declarative schema validation errors and correlate them with
-- objects/entities from the original user input
--
-- Produces a list of errors with the following format:
--
-- ```lua
-- {
--   entity_type = "service",    -- service, route, plugin, etc
--   entity_id   = "<uuid>",     -- useful to correlate errors across fk relationships
--   entity_name = "my-service", -- may be nil
--   entity_tags = { "my-tag" },
--   entity = {                  -- the full entity object
--     name = "my-service",
--     id  = "<uuid>",
--     tags = { "my-tag" },
--     host = "127.0.0.1",
--     protocol = "tcp",
--     path = "/path",
--   },
--   errors = {
--     {
--       type = "entity"
--       message = "failed conditional validation given value of field 'protocol'",
--     },
--     {
--       type = "field"
--       field = "path",
--       message = "value must be null",
--     }
--   }
-- }
-- ```
--
-- Nested foreign relationships are hoisted up to the top level, so
-- given the following input:
--
-- ```lua
-- {
--   services = {
--     name = "matthew",
--     url = "http:/127.0.0.1:80/",
--     routes = {
--       {
--         name = "joshua",
--         protocols = { "nope" },            -- invalid protocol
--       }
--     },
--     plugins = {
--       {
--         name = "i-am-not-a-real-plugin",   -- nonexistent plugin
--         config = {
--           foo = "bar",
--         },
--       },
--       {
--         name = "http-log",
--         config = {},                       -- missing required field(s)
--       },
--     },
--   }
-- }
-- ```
-- ... the output error array will have three entries, one for the route,
-- and one for each of the plugins.
--
-- Errors for record fields and nested schema properties are rolled up and
-- added to their parent entity, with the full path to the property
-- represented as a period-delimited string:
--
-- ```lua
-- {
--   entity_type = "plugin",
--   entity_name = "http-log",
--   entity = {
--     name = "http-log",
--     config = {
--       -- empty
--     },
--   },
--   errors = {
--     {
--       field = "config.http_endpoint",
--       message = "missing host in url",
--       type = "field"
--     }
--   },
-- }
-- ```
--
---@param  err_t table
---@param  input table
---@return table
function _M:declarative_config_flattened(err_t, input)
  if type(err_t) ~= "table" then
    error("err_t must be a table", 2)
  end

  if type(input) ~= "table" then
    error("err_t input is nil or not a table", 2)
  end

  local flattened = flatten_errors(input, err_t)

  err_t = self:declarative_config(err_t)

  err_t.flattened_errors = flattened

  return err_t
end


return _M
