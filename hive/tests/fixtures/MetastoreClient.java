import java.util.HashMap;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.hive.metastore.HiveMetaStoreClient;
import org.apache.hadoop.hive.metastore.api.Database;

/** Uses the distribution's own client to perform real Thrift/database operations. */
public class MetastoreClient {
    public static void main(String[] args) throws Exception {
        Configuration conf = new Configuration(false);
        conf.set("hive.metastore.uris", "thrift://127.0.0.1:9083");
        conf.set("metastore.thrift.uris", "thrift://127.0.0.1:9083");
        conf.set("hive.metastore.client.socket.timeout", "5s");
        conf.set("metastore.client.socket.timeout", "5s");
        HiveMetaStoreClient client = new HiveMetaStoreClient(conf);
        try {
            if (args[0].equals("ready")) {
                if (!client.getAllDatabases().contains("default")) throw new AssertionError("default database missing");
                System.out.println("TEST_HIVE_READY");
            } else if (args[0].equals("create")) {
                Database db = new Database();
                db.setName(args[1]);
                db.setDescription("universal lifecycle persistence test");
                db.setLocationUri("file:///kubedoop/run/warehouse/" + args[1] + ".db");
                db.setParameters(new HashMap<String, String>());
                client.createDatabase(db);
                System.out.println(client.getDatabase(args[1]).getName());
            } else if (args[0].equals("check")) {
                Database db = client.getDatabase(args[1]);
                if (!db.getName().equals(args[1])) throw new AssertionError("database identity changed");
                if (!db.getDescription().equals("universal lifecycle persistence test")) throw new AssertionError("database contents lost");
                System.out.println(db.getName());
            } else {
                throw new IllegalArgumentException(args[0]);
            }
        } finally {
            client.close();
        }
    }
}
