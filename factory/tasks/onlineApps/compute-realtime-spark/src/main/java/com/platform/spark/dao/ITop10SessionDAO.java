package com.platform.spark.dao;

import com.platform.spark.domain.Top10Session;

/**
 * top10活跃session的DAO接口
 * @author AllDataDC
 *
 */
public interface ITop10SessionDAO {

	void insert(Top10Session top10Session);
	
}
