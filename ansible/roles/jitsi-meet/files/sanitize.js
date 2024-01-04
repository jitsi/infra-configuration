// sanitize
if (location.hash) {
    var baseUrl = [location.protocol, '//', location.host, location.pathname, location.search].join('');
    var paramStr = location.hash;
    var params = {};
    paramStr.substr(1).split('&').forEach(
        function(paramEntry) {
            var param = paramEntry.split('=');
            var key = param[0];
            if (!key
                || key === 'interfaceConfig.DEFAULT_LOCAL_DISPLAY_NAME'
                || key === 'interfaceConfig.DEFAULT_REMOTE_DISPLAY_NAME'
                || key === 'interfaceConfig.APP_NAME'
                || key === 'config.analyticsScriptUrls') {
                return;
            }
            var value = param[1];
            try {

            } catch (e) {
                console.warn(e);
                return;
            }
            params[key] = value;
        }
    );
    paramsToReplace = '#';
    Object.keys(params).forEach(function(key){
        paramsToReplace += key + '=' + params[key] + '&';
    });
    paramsToReplace = paramsToReplace.slice(0, -1);
    window.history.replaceState({}, document.title, baseUrl + paramsToReplace);
}
