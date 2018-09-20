

public with sharing class EnterpriseKeyService {

	@InvocableMethod(label='Enterprise Object Interface' description='Provides a Transaction Safe Method to Insert/Retrieve Salesforce Object Keys based on Enterprise UUIDs')
	public static List < System_Key_Structure__c > ObjectInterface ( List < System_Key_Structure__c > inputParams ) {

		List < System_Key_Structure__c > results = new List < System_Key_Structure__c > ();
		//Map < String, String > uuidToSfdcMap = new Map < String, String > ();
		Map < String, Map < String, String >> objTypeMap = new Map < String, Map < String, String >> ();

		logEntryHeader ('ObjectInterface','Start','System Key Structure Data - inputParams' );
		system.debug ( inputParams );

		// iterate through each Key Struct building Maps for future processing
		for ( System_Key_Structure__c sks : inputParams ) {
			
			// add the UUID indexed by Object Type
			if ( objTypeMap.containsKey ( sks.Object_Type__c ) == FALSE ) {
				objTypeMap.put ( sks.Object_Type__c, new Map < String, String > ());
			}

			if ( objTypeMap.get ( sks.Object_Type__c ).containsKey ( sks.Enterprise_UUID__c ) == FALSE ) {
				objTypeMap.get ( sks.Object_Type__c ).put ( sks.Enterprise_UUID__c, null );
			}

			results.add ( sks );
		}

		logEntryHeader ('ObjectInterface','Post Map Creation','object type map' );
		System.debug ( objTypeMap );

		// for each object type process the UUID insert/lookup method
		for ( String objectType : objTypeMap.keySet ()) {
			// replace the mapped keys by object type
			objTypeMap.put ( objectType, uuidLookupInsert ( objTypeMap.get ( objectType ), objectType ));
		}

		logEntryHeader ('ObjectInterface','Post Insert/Lookup','object type map' );
		System.debug ( objTypeMap );

		// update the results with new ID values
		for ( System_Key_Structure__c sks : results ) {
			sks.salesforce_id__c = objTypeMap.get ( sks.Object_Type__c ).get ( sks.Enterprise_UUID__c );
		}

		logEntryHeader ('ObjectInterface','Exit','results' );
		System.debug ( results );

		return results;
	}

	// method to Insert or Lookup a UUID by object type
	public static Map < String, String > uuidLookupInsert ( Map < String, String > keyMap, String objectType ) {
		
		Map < String, String > returnMap = new Map < String, String > ();
		Set < String > uuidSet = keyMap.keySet ();

		logEntryHeader ('uuidLookupInsert','Entry','input keyMap' );
		System.debug ( keyMap );

		// call the Look up routine
		returnMap.putAll ( uuidLookup ( keyMap.keySet (), objectType ));

		logEntryHeader ('uuidLookupInsert','Post Lookup','returnMap' );
		System.debug ( returnMap );

		// remove the uuids that were found
		uuidSet.removeAll ( returnMap.keySet ());

		logEntryHeader ('uuidLookupInsert','Removed all found keys','uuidSet' );
		System.debug ( uuidSet );

		// attempt to insert remaining UUIDs
		returnMap.putAll ( uuidInsert ( uuidSet, objectType ));

		logEntryHeader ('uuidLookupInsert','Post Insert','returnMap' );
		System.debug ( returnMap );

		return returnMap;
	}

	public static Map < String, String > uuidLookup ( Set < String > uuids, String objectType ) {

		Map < String, String > returnMap = new Map < String, String > ();
		Set < String > uuidForLookup = new Set < String > ();

		logEntryHeader ('uuidLookup','Entry','uuids' );
		System.debug ( uuids );

		// call the UUID look up routine for each 400 of UUIDs
		integer i = 0;

		for ( String uuid : uuids ) {
			uuidForLookup.add ( uuid );
			i++;
			if ( i == 400 ) {
				// do the lookup, store and flush the counter
				returnMap.putAll ( uuidLookupChunkHandler ( uuidForLookup, objectType ));
				uuidForLookup.clear ();
				i = 0;
			}
		}
		if ( i != 0 ) {
			// run the chunk handler as the for loop exited on a non-400 count
			returnMap.putAll ( uuidLookupChunkHandler ( uuidForLookup, objectType ));
		}

		logEntryHeader ('uuidLookup','Exit','returnMap' );
		System.debug ( returnMap );

		return returnMap;
	}

	// for a set of UUIDs by object type, fetch Salesforce IDs in a Chunk
	public static Map < String, String > uuidLookupChunkHandler ( Set < String > uuids, String objectType ) {

		Map < String, String > returnMap = new Map < String, String > ();

		// fetch the UUID field name
		String uuidFieldName = enterpriseKeyField ( objectType );

		logEntryHeader ('uuidLookupChunkHandler','Entry','uuids' );
		System.debug ( uuids );

		// build query string
		// Note: max length for query string is 20,000 characters
		// UUIDs are max length 32 characters, so 
		// SELECT +  WHERE Clause = 30 chars
		// Each UUID - 15 base + 32 max on UUID -> 47 chars
		// Max: 424 UUID keys can be processed by this method
		String soql = 'SELECT ID,' + uuidFieldName + ' FROM ' + objectType + ' WHERE ';
		for ( String uuid : uuids ) {
			soql = soql + '(' + uuidFieldName + '= \'' + uuid + '\')OR';
			uuids.add ( uuid );
		}

		// remove trailing AND
		soql = soql.left ( soql.length () - 2 );

		logEntryHeader ('uuidLookupChunkHandler','Pre Query','query' );
		System.debug ( soql );
		
		// execute query
		List < sObject > sObjList = Database.Query ( soql );

		logEntryHeader ('uuidLookupChunkHandler','Post Query','sObjList' );
		System.debug ( sObjList );

		// set ID's of found records
		for ( sObject obj : sObjList ) {
			returnMap.put ( (String) obj.get ( uuidFieldName ), (String) obj.get ( 'ID' ));
		}

		logEntryHeader ('uuidLookupChunkHandler','Exit','returnMap' );
		System.debug ( returnMap );

		return returnMap;
	}

	// for a set of uuids, attempt to insert into object type
	public static Map < String, String > uuidInsert ( Set < String > uuids, String objectType ) {

		Map < String, String > returnMap = new Map < String, String > ();
		List < sObject > sObjectsForInsert = new List < sObject > ();

		String uuidFieldName = enterpriseKeyField ( objectType );

		for ( String uuid : uuids ) {
			sObject item = Schema.getGlobalDescribe ().get ( objectType ).newSObject ();
			item.put ( uuidFieldName, uuid );
			sObjectsForInsert.add ( item );
		}

		// attempt the insert
		Database.SaveResult [] insertResults = Database.Insert ( sObjectsForInsert, FALSE );
		
		// inspect the save results - create new set for requery if we find any that failed
		integer i = 0;
		Set < String > requeryUuids = new Set < String > ();

		for ( Database.SaveResult sr : insertResults ) {
			if ( sr.isSuccess ()) {
				// insert success
				returnMap.put ( (String) sObjectsForInsert[i].get ( uuidFieldName ), (String) sr.getId ());
			} else {
				// insert failed, set to attempt requery
				requeryUuids.add ( (String) sObjectsForInsert[i].get ( uuidFieldName ));
			}
			i++; // iterate counter
		}

		// requery if necessary
		if ( requeryUuids.size () > 0 ) {
			returnMap.putAll ( uuidLookup ( requeryUuids, objectType ));
		}

		return returnMap;
	}

	// query the Custom Metadata definition for Enterprise Key Field
	public static string enterpriseKeyField ( String objectType ) {
		List < Enterprise_Key_Field__mdt > ekfs = new List < Enterprise_Key_Field__mdt > ([ SELECT object_type__r.qualifiedapiname
																									, enterprise_key__r.qualifiedapiname 
																									FROM Enterprise_Key_Field__mdt 
																									WHERE object_type__r.qualifiedapiname =: objectType ]);
		if ( ekfs.size () > 0 ) {
			return ekfs[0].enterprise_key__r.qualifiedapiname;
		} else {
			return null;
		}
	}

	public static void logEntryHeader ( String methodName, String section, String note ) {
		System.debug ( '[ ' + methodName + ' ] - [ ' + section + ' ] Note: ' + note );
	}

}