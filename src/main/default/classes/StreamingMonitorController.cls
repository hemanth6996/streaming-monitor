public abstract class StreamingMonitorController {
    @AuraEnabled
    public static void publishPlatformEvent(String eventName, String eventPayload) {
        // Load event type
        Type platformEventType;
        try {
            platformEventType = Type.forName(eventName);
        } catch (Exception e) {
            throw new AuraHandledException('Unknown platform event type: '+ eventName);
        }
        // Create event instance
        SObject event;
        try {
            event = (SObject) JSON.deserialize(eventPayload, platformEventType);
        } catch (Exception e) {
            throw new AuraHandledException('Failed to instantiate '+ eventName +' platform event with provided data: '+ eventPayload);
        }
        // Publish event
        Database.SaveResult result = Eventbus.publish(event);
        if (!result.isSuccess()) {
            String errorMessage = 'Failed to publish '+ eventName +': EventBus publish error.';
            System.debug(errorMessage);
            for(Database.Error error : result.getErrors()) {
                System.debug('Error: ' + error.getStatusCode() +' - '+ error.getMessage() +' - '+ error.getFields());
            }
            throw new AuraHandledException(errorMessage);
        }
    }

    @AuraEnabled
    public static void publishGenericEvent(String eventName, String eventPayload) {
        // Load event type
        String channel = '/u/'+ eventName;
        List<StreamingChannel> channels = [SELECT Id FROM StreamingChannel WHERE Name = :channel LIMIT 1];
        if (channels.size() != 1) {
            throw new AuraHandledException('Unknown generic event type: '+ eventName);
        }
        // Posting event in a job in order to be able to call the REST API
        System.enqueueJob(new QueueableGenericEventPost(channels[0].Id, eventPayload));
    }

    @AuraEnabled
    public static Map<String, List<ComboBoxItem>> getAllEventChannels() {
        Map<String, List<ComboBoxItem>> channels = new Map<String, List<ComboBoxItem>>();
        channels.put('PushTopicEvent', getPushTopicEventChannels());
        channels.put('GenericEvent', getGenericEventChannels());
        channels.put('PlatformEvent', getPlatformEventChannels());
        channels.put('ChangeDataCaptureEvent', getChangeDataCaptureEventChannels());
        return channels;
    }

    public static List<ComboBoxItem> getPushTopicEventChannels() {
        List<PushTopic> topics = [SELECT Name FROM PushTopic ORDER BY Name];
        List<ComboBoxItem> items = new List<ComboBoxItem>();
        for (PushTopic topic : topics) {
            items.add(new ComboBoxItem(topic.Name, topic.Name));
        }
        return items;
    }

    public static List<ComboBoxItem> getGenericEventChannels() {
        List<StreamingChannel> channels = [SELECT Name FROM StreamingChannel ORDER BY Name];
        List<ComboBoxItem> items = new List<ComboBoxItem>();
        for (StreamingChannel channel : channels) {
            String name = channel.Name.substring(3);
            items.add(new ComboBoxItem(name, name));
        }
        return items;
    }

    public static List<ComboBoxItem> getChangeDataCaptureEventChannels() {
        List<EntityDefinition> entities = [SELECT Label, QualifiedApiName FROM EntityDefinition WHERE QualifiedApiName LIKE '%ChangeEvent' ORDER BY Label];
        List<ComboBoxItem> items = new List<ComboBoxItem>();
        for (EntityDefinition entity : entities) {
            items.add(new ComboBoxItem(entity.Label, entity.QualifiedApiName));
        }
        return items;
    }

    public static List<ComboBoxItem> getPlatformEventChannels() {
        List<EntityDefinition> entities = [SELECT Label, QualifiedApiName FROM EntityDefinition WHERE IsCustomizable=true AND QualifiedApiName LIKE '%e' ORDER BY Label ASC];
        List<ComboBoxItem> items = new List<ComboBoxItem>();
        for (EntityDefinition entity : entities) {
            if (entity.QualifiedApiName.endsWith('__e')) {
                items.add(new ComboBoxItem(entity.Label, entity.QualifiedApiName));
            }
        }
        return items;
    }

    public class ComboBoxItem {
        @AuraEnabled
        public String label;
        
        @AuraEnabled
        public String value;

        public ComboBoxItem(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    private class QueueableGenericEventPost implements Queueable, Database.AllowsCallouts {
        private String channelId;
        private String payload;

        public QueueableGenericEventPost(String channelId, String payload) {
            this.channelId = channelId;
            this.payload = payload;
        }
        
        public void execute(QueueableContext context) {
            String restAPIURL = URL.getSalesforceBaseUrl().toExternalForm()
                +'/services/data/v43.0/sobjects/StreamingChannel/'+ channelId +'/push';  
            HttpRequest httpRequest = new HttpRequest();
            httpRequest.setMethod('POST');
            httpRequest.setHeader('Content-Type', 'application/json');
            httpRequest.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionID());
            httpRequest.setEndpoint(restAPIURL);
            httpRequest.setBody('{ "pushEvents": [ { "payload": "'+ payload +'", "userIds": [] } ] }');
            Http http = new Http();
            HttpResponse httpResponse = http.send(httpRequest);
            if (httpResponse.getStatusCode() != 200 ) {
                System.debug('HTTP '+ httpResponse.getStatusCode() +': '+ httpResponse.getBody());
                throw new CalloutException(httpResponse.getBody());
            }
        }
    }
}