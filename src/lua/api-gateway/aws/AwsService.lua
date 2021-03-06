--- Base Class for working with AWS Services.
-- It's responsible for making API Requests to most of the AWS Services
--
-- Created by IntelliJ IDEA.
-- User: ddascal
-- Date: 24/11/14
-- Time: 18:46
--

local _M = { _VERSION = '0.01' }

local setmetatable = setmetatable
local error = error
local debug_mode = ngx.config.debug
local http = require"api-gateway.aws.httpclient.http"
local AWSV4S = require"api-gateway.aws.AwsV4Signature"
local IamCredentials = require"api-gateway.aws.AWSIAMCredentials"
local cjson = require"cjson"

local http_client = http:new()
local iam_credentials

local function tableToString(table_ref)
    local s = ""
    local o = table_ref or {}
    for k, v in pairs(o) do
        s = s .. ", " .. k .. "=" .. tostring(v)
    end
    return s
end

---
-- @param o object containing info about the AWS Service and Credentials or IAM User to use
-- o.aws_region      - AWS Region
-- o.aws_service     - the AWS Service to call
-- o.aws_secret_key  - AWS Credential
-- o.aws_access_key  - AWS Credential
-- o.aws_iam_user    - optional. if aws_secret_key,aws_access_key pair is missing you can provide an iam_user
-- o.security_credentials_host - optional. the AWS URL to read security credentials from and figure out the iam_user
-- o.security_credentials_port - optional. the port used when connecting to security_credentials_host
-- o.shared_cache_dict - optional. AWSIAMCredentials uses it to store IAM Credentials.
--
-- NOTE: class inheirtance inspired from: http://www.lua.org/pil/16.2.html
function _M:new(o)
    ngx.log(ngx.DEBUG, "AwsService() supercls=", tostring(o.___super))
    local o = o or {}
    setmetatable(o, self)
    self.__index = self
    if not o.___super then
        self:constructor(o)
    end

    return o
end

function _M:constructor(o)
    ngx.log(ngx.DEBUG, "AwsService() constructor ")
    local s = tableToString(o)
    ngx.log(ngx.DEBUG, "init object=" .. s)
    self:throwIfInitParamsInvalid(o)

    local secret = self.aws_secret_key or ""
    local key = self.aws_access_key or ""

    -- if accessKey or secret is not provided then try with Iam User
    if (key == "" or secret == "") then
        ngx.log(ngx.DEBUG, "Initializing IamCredentials as aws_secret_key,aws_access_key were not valid: [", secret, ",", key, "]")
        iam_credentials = IamCredentials:new({
            shared_cache_dict = o.shared_cache_dict,
            iam_user = o.aws_iam_user,
            security_credentials_host = o.security_credentials_host,
            security_credentials_port = o.security_credentials_port
        })
    end
end

function _M:throwIfInitParamsInvalid(o)
    if (o == nil) then
        error("Could not initialize. Missing init object. Please configure the AWS Service properly.")
    end


    local service = o.aws_service or ""
    if service == "" then
        error("aws_service is missing. Please provide one.")
    end

    local region = o.aws_region or ""
    if region == "" then
        error("aws_region is missing. Please provide one.")
    end
end

function _M:debug(...)
    if debug_mode then
        ngx.log(ngx.DEBUG, "AwsService: ", ...)
    end
end

function _M:getHttpClient()
    return http_client
end

function _M:getAWSHost()
    return self.aws_service .. "." .. self.aws_region .. ".amazonaws.com"
end

function _M:getIamUserCredentials()
    return iam_credentials:getSecurityCredentials()
end

function _M:getCredentials()
    local secret = self.aws_secret_key or ""
    local key = self.aws_access_key or ""
    local token, date, timestamp

    local return_obj = {
        aws_secret_key = secret,
        aws_access_key = key
    }

    if (key == "" or secret == "") then
        if (iam_credentials == nil) then
            ngx.log(ngx.WARN, "Could not discover IAM User. Please provide aws_access_key and aws_secret_key")
            return return_obj
        end
        key, secret, token, date, timestamp = iam_credentials:getSecurityCredentials()
        return_obj.token = token
        return_obj.aws_secret_key = secret
        return_obj.aws_access_key = key
    end
    ngx.log(ngx.DEBUG, "getCredentials():", return_obj.aws_access_key, " >> ", return_obj.aws_secret_key, " >> ", return_obj.token)
    return return_obj
end

function _M:getAuthorizationHeader(http_method, path, uri_args, body)
    local credentials = self:getCredentials()
    credentials.aws_region = self.aws_region
    credentials.aws_service = self.aws_service
    local awsAuth = AWSV4S:new(credentials)
    local authorization = awsAuth:getAuthorizationHeader(http_method,
        path, -- "/"
        uri_args, -- ngx.req.get_uri_args()
        body)
    return authorization, awsAuth
end

---
-- Hook to overwrite the request object before sending the request through to AWS
-- By default it returns the same object
-- @param object request object
--
function _M:getRequestObject(object)
    return object
end

function _M:getRequestArguments(actionName, parameters)
    local urlencoded_args = "Action=" .. actionName
    if parameters ~= nil then
        for key, value in pairs(parameters) do
            local proper_val = ngx.re.gsub(tostring(value), "&", "%26", "ijo")
            urlencoded_args = urlencoded_args .. "&" .. key .. "=" .. (proper_val or "")
        end
    end
    return urlencoded_args
end

---
-- Generic function used to call any AWS Service.
-- NOTE: All methods use AWS V4 signature, so this should be compatible with all the new AWS services.
-- More info: http://docs.aws.amazon.com/kms/latest/APIReference/CommonParameters.html
--
-- @param actionName Name of the AWS Action. i.e. GenerateDataKey
-- @param arguments Extra arguments needed for the action
-- @param path AWS Path. Default value is "/"
-- @param http_method Request HTTP Method. Default value is "GET"
-- @param useSSL Call using HTTPS or HTTP. Default value is "HTTP"
-- @param contentType Specifies how to deliver the content to the AWS Service.
--         Possible values are:   "application/x-amz-json-1.1" or "application/x-www-form-urlencoded"
-- @param extra_headers Any extra headers to be added to the request for the AWS Service
--
function _M:performAction(actionName, arguments, path, http_method, useSSL, timeout, contentType, extra_headers)
    local host = self:getAWSHost()
    local credentials = self:getCredentials()
    local request_method = http_method or "GET"

    local arguments = arguments or {}
    local query_string = self:getRequestArguments(actionName, arguments)
    local request_path = path or "/"

    local uri_args, request_body = arguments, ""
    uri_args.Action = actionName

    local content_type = contentType or "application/x-amz-json-1.1"

    if content_type == "application/x-amz-json-1.1" then
        request_body = cjson.encode(arguments)
    elseif content_type == "application/x-www-form-urlencoded" then
        request_body = query_string
    end

    if request_method ~= "GET" then
        uri_args = {}
    end

    local scheme = "http"
    local port = 80
    if useSSL == true then
        scheme = "https"
        port = 443
    end


    local authorization, awsAuth = self:getAuthorizationHeader(request_method, request_path, uri_args, request_body)

    local t = self.aws_service_name .. "." .. actionName
    local request_headers = {
        Authorization = authorization,
        ["X-Amz-Date"] = awsAuth.aws_date,
        ["Accept"] = "application/json",
        ["Content-Type"] = content_type,
        ["X-Amz-Target"] = t,
        ["x-amz-security-token"] = credentials.token
    }
    if ( extra_headers ~= nil ) then
        for headerName, headerValue in pairs(extra_headers) do
            request_headers[headerName] = headerValue
        end
    end


    -- this race condition has to be AFTER the authorization header has been calculated
    if request_method == "GET" then
        request_path = request_path .. "?" .. query_string
    end

    if (self.aws_debug == true) then
        ngx.log(ngx.DEBUG, "Calling AWS:", request_method, " ", scheme, "://", host, ":", port, request_path, ". Body=", request_body)
        local s = tableToString(request_headers)
        ngx.log(ngx.DEBUG, "Calling AWS: Headers:", s)
    end

    local ok, code, headers, status, body = self:getHttpClient():request(self:getRequestObject({
        scheme = scheme,
        port = port,
        timeout = timeout or 60000,
        url = request_path, -- "/"
        host = host,
        body = request_body,
        method = request_method,
        headers = request_headers,
        keepalive = self.aws_conn_keepalive or 30000, -- 30s keepalive
        poolsize = self.aws_conn_pool or 100 -- max number of connections allowed in the connection pool
    }))

    if (self.aws_debug == true) then
        local s = tableToString(headers)
        ngx.log(ngx.DEBUG, "AWS Response:", "code=", code, ", headers=", s, ", status=", status, ", body=", body)
    end

    return ok, code, headers, status, body
end

return _M





