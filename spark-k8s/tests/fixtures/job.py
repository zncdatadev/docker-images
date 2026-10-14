import os
import sys
from pathlib import Path
from pyspark.sql import SparkSession

Path("/kubedoop/run/python-driver-pid").write_text(str(os.getpid()))
spark = SparkSession.builder.appName("universal-process-regression").getOrCreate()
spark.sparkContext.setLogLevel("WARN")
path = "/kubedoop/run/result"
if not os.path.isdir(path):
    spark.range(40).selectExpr("id", "id * 2 AS doubled").write.parquet(path)
rows = spark.read.parquet(path)
assert rows.count() == 40
assert rows.where("doubled != id * 2").count() == 0
print("TEST_SPARK_REAL_COMPUTE_AND_PERSISTENCE_OK", flush=True)
if "--hold" in sys.argv:
    while True:
        import time
        time.sleep(0.2)
spark.stop()
